#!/usr/bin/env python3
"""Daily Gatekeeper workload report (MAPCO-11867). Stdlib only; runs with python3 -I.

Reads the live workload ConstraintTemplates, Constraints, Namespaces and the workload kinds
the Constraints match, writes a projection of them, runs gator on it, routes each namespace
to a team, posts one summary per team to the team's webhook and pushes the run to Loki.
No Rego is copied: gator evaluates the deployed templates and Constraints, exemptions
included. See the chart README ("Daily report") for the Loki contract.

  report.py --from-cluster [--dry-run] [--gator PATH] --teams teams.json
  report.py --from-files DIR [--dry-run] --gator PATH --teams teams.json

--from-cluster reads $KUBE_API (default: the in-cluster API with the Pod's ServiceAccount);
for a local run point it at `kubectl proxy`. --from-files reads raw API JSON from DIR, one
file per API path ("/apis/apps/v1/deployments" -> "apis_apps_v1_deployments.json").
--dry-run logs the messages instead of posting them; the Loki push still happens when
LOKI_URL is set. Exit code: 0 when the run status is "ok", 1 otherwise.
"""

import argparse
import copy
import datetime
import hashlib
import http.client
import json
import os
import re
import ssl
import subprocess
import sys
import tarfile
import traceback
import urllib.error
import urllib.parse
import urllib.request

RULE_NAMES = {"K8sWorkloadCpuRatio": "cpuRatio", "K8sWorkloadMcLabels": "mclabels"}
RULE_TITLES = {"cpuRatio": "CPU limit not 4x request", "mclabels": "mclabels"}
RULE_SHORT = {"cpuRatio": "CPU", "mclabels": "mclabels"}
# Workload kinds the report can list, by (apiGroup, kind).
WORKLOAD_RESOURCES = {
    ("apps", "Deployment"): ("apps/v1", "/apis/apps/v1/deployments"),
    ("apps", "StatefulSet"): ("apps/v1", "/apis/apps/v1/statefulsets"),
}
KIND_PREFIX = {"Deployment": "", "StatefulSet": "sts/"}
SILENCED = "silenced"
PAGE_SIZE = 500
AUDIT_MAX_AGE = datetime.timedelta(hours=2)
# An upgrade recreates the ConstraintTemplates, so their Constraints too; the first audits
# after that can report totalViolations 0 before the template is loaded.
AUDIT_SETTLE = datetime.timedelta(minutes=10)
GATOR_TIMEOUT = 300
HTTP_TIMEOUT = 30
LAST_APPLIED = "kubectl.kubernetes.io/last-applied-configuration"
CONTAINER_RE = re.compile(r' container "([^"]+)"')
MCLABELS_RE = re.compile(r"mclabels are missing or invalid: (.*?)\. To exempt", re.S)
PROBLEM_SPLIT_RE = re.compile(r"(?<=\)), ")
URL_RE = re.compile(r"https?://\S+")
INPUT_FILE_RE = re.compile(r"^[0-9]{6}\.json$")  # write_inputs() file names


class ReportError(Exception):
    """A failure that stops the run: it is reported as status "skipped"."""


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def redact(text):
    """Never let a URL (webhooks carry their secret in the path) into a message or log."""
    return URL_RE.sub("<url>", str(text))


def hide(text, url):
    """redact(), and also hide `url` and its path in any form: a malformed webhook value
    (no scheme, inner whitespace) is not caught by URL_RE, and http.client quotes only the
    path in its errors."""
    text = redact(text)
    path = urllib.parse.urlsplit(url).path
    for secret in sorted({url, url.strip(), path, path.lstrip("/")}, key=len, reverse=True):
        if len(secret) >= 4:
            text = text.replace(secret, "<url>")
    return text


def rule_of(constraint_kind):
    return RULE_NAMES.get(constraint_kind, constraint_kind)


# ---------------------------------------------------------------------------------------
# Pure functions
# ---------------------------------------------------------------------------------------

def _metadata(meta, namespaced):
    out = {"name": meta["name"]}
    if namespaced:
        out["namespace"] = meta.get("namespace", "")
    if meta.get("labels"):
        out["labels"] = dict(meta["labels"])
    annotations = {k: v for k, v in (meta.get("annotations") or {}).items() if k != LAST_APPLIED}
    if annotations:
        out["annotations"] = annotations
    return out


def _containers(items):
    return [{"name": c.get("name", ""), "resources": copy.deepcopy(c.get("resources") or {})}
            for c in items or []]


def project_workload(item, api_version, kind):
    """What the workload Rego can read: metadata, Pod template labels/annotations and each
    container's name and resources. env, images, volumes etc. never leave the API call."""
    template = item.get("spec", {}).get("template", {}) or {}
    tmeta = template.get("metadata", {}) or {}
    tspec = template.get("spec", {}) or {}
    pod_meta = {k: dict(tmeta[k]) for k in ("labels", "annotations") if tmeta.get(k)}
    pod_spec = {}
    for field in ("containers", "initContainers", "ephemeralContainers"):
        if field in tspec:
            pod_spec[field] = _containers(tspec[field])
    spec = {"template": {"metadata": pod_meta, "spec": pod_spec}}
    if "selector" in item.get("spec", {}):
        spec["selector"] = copy.deepcopy(item["spec"]["selector"])
    return {"apiVersion": api_version, "kind": kind,
            "metadata": _metadata(item["metadata"], True), "spec": spec}


def project_namespace(item):
    return {"apiVersion": "v1", "kind": "Namespace", "metadata": _metadata(item["metadata"], False)}


def project_template(item):
    return {"apiVersion": "templates.gatekeeper.sh/v1", "kind": "ConstraintTemplate",
            "metadata": {"name": item["metadata"]["name"]}, "spec": copy.deepcopy(item["spec"])}


def project_constraint(item, kind):
    """The Constraint as deployed, but warn: gator exits 1 on deny results. Only this copy
    goes into the input, under the original name, so no result is counted twice."""
    spec = copy.deepcopy(item.get("spec", {}))
    spec["enforcementAction"] = "warn"
    return {"apiVersion": "constraints.gatekeeper.sh/v1beta1", "kind": kind,
            "metadata": {"name": item["metadata"]["name"]}, "spec": spec}


def matched_workload_kinds(constraints):
    """(apiGroup, kind) pairs the Constraints match. Raises on kinds the report can't list."""
    kinds = set()
    for c in constraints:
        match_kinds = c.get("spec", {}).get("match", {}).get("kinds")
        if not match_kinds:
            raise ReportError("constraint %s matches every kind; the report needs match.kinds"
                              % c["metadata"]["name"])
        for mk in match_kinds:
            for group in mk.get("apiGroups") or [""]:
                for kind in mk.get("kinds") or []:
                    if group == "*" or kind == "*":
                        raise ReportError("constraint %s matches a wildcard kind" % c["metadata"]["name"])
                    if (group, kind) not in WORKLOAD_RESOURCES:
                        raise ReportError("constraint %s matches %s/%s, which the report can't list"
                                          % (c["metadata"]["name"], group, kind))
                    kinds.add((group, kind))
    return sorted(kinds)


def parse_mclabels_problems(msg):
    """Split an mclabels message into missing and invalid label keys (D7). A problem is
    "missing" when the label is absent; anything else (empty, owner not allowed,
    environment=undefined, or text this code doesn't know) is "invalid"."""
    m = MCLABELS_RE.search(msg)
    missing, invalid = set(), set()
    if not m:
        return missing, {"(unparsed)"}
    for problem in PROBLEM_SPLIT_RE.split(m.group(1)):
        key, _, rest = problem.partition(" ")
        (missing if rest == "(missing)" else invalid).add(key)
    return missing, invalid


def parse_gator(results):
    """gator's -o json results -> one finding per result."""
    findings = []
    for r in results or []:
        obj = r.get("violatingObject") or {}
        meta = obj.get("metadata") or {}
        constraint = r.get("constraint") or {}
        msg = r.get("msg", "")
        rule = rule_of(constraint.get("kind", ""))
        f = {"rule": rule, "constraint": constraint.get("metadata", {}).get("name", ""),
             "constraintKind": constraint.get("kind", ""), "kind": obj.get("kind", ""),
             "namespace": meta.get("namespace", ""), "name": meta.get("name", ""), "msg": msg,
             "container": None, "missing": set(), "invalid": set()}
        if rule == "cpuRatio":
            c = CONTAINER_RE.search(msg)
            f["container"] = c.group(1) if c else "(unknown)"
        elif rule == "mclabels":
            f["missing"], f["invalid"] = parse_mclabels_problems(msg)
        findings.append(f)
    return findings


def group_workloads(findings):
    """One entry per (rule, kind, namespace, name) (R7). Containers and problems are the
    union over every result for that workload, so a workload matched by both a warn and an
    enforced Constraint counts once, and so do its containers."""
    out = {}
    for f in findings:
        key = (f["rule"], f["kind"], f["namespace"], f["name"])
        w = out.setdefault(key, {"rule": f["rule"], "kind": f["kind"], "namespace": f["namespace"],
                                 "name": f["name"], "containers": set(), "missing": set(),
                                 "invalid": set(), "msgs": []})
        if f["container"]:
            w["containers"].add(f["container"])
        w["missing"] |= f["missing"]
        w["invalid"] |= f["invalid"]
        if f["msg"] not in w["msgs"]:
            w["msgs"].append(f["msg"])
    return out


def route(namespace, teams):
    """First entry whose regex matches the whole name wins (teams.json is ordered exact
    names first, then globs). team null -> silenced; no match -> defaultTeam."""
    for e in teams["entries"]:
        if re.fullmatch(e["regex"], namespace):
            return e["team"] if e["team"] else SILENCED
    return teams["defaultTeam"]


def all_teams(teams):
    out = list(teams["teams"])
    if teams["defaultTeam"] not in out:
        out.append(teams["defaultTeam"])
    return out + [SILENCED]


def summarize(workloads, teams, rules):
    """-> {team: {namespace: {rule: stats}}} and {(team, rule): totals} (zeros included)."""
    by_team = {}
    for w in workloads.values():
        team = route(w["namespace"], teams)
        s = by_team.setdefault(team, {}).setdefault(w["namespace"], {}).setdefault(
            w["rule"], {"workloads": 0, "containers": 0, "missing": 0, "invalid": 0, "names": []})
        s["workloads"] += 1
        s["containers"] += len(w["containers"])
        s["missing"] += 1 if w["missing"] else 0
        s["invalid"] += 1 if w["invalid"] else 0
        s["names"].append(KIND_PREFIX.get(w["kind"], w["kind"].lower() + "/") + w["name"])
    for namespaces in by_team.values():
        for rules_ in namespaces.values():
            for s in rules_.values():
                s["names"] = sorted(set(s["names"]))
    totals = {}
    for team in all_teams(teams):
        for rule in rules:
            t = {"workloads": 0, "containers": 0, "missing": 0, "invalid": 0}
            for rules_ in by_team.get(team, {}).values():
                for k in t:
                    t[k] += rules_.get(rule, {}).get(k, 0)
            totals[(team, rule)] = t
    return by_team, totals


def describe_counts(rule, s):
    if rule == "cpuRatio":
        return "%s: %d workloads (%d containers)" % (RULE_TITLES[rule], s["workloads"], s["containers"])
    if rule == "mclabels":
        return "%s: %d workloads (missing %d, invalid %d)" % (
            RULE_TITLES[rule], s["workloads"], s["missing"], s["invalid"])
    return "%s: %d workloads" % (RULE_TITLES.get(rule, rule), s["workloads"])


def dashboard_link(dashboard_url, team, run_id):
    sep = "&" if "?" in dashboard_url else "?"
    return "%s%s%s" % (dashboard_url, sep, urllib.parse.urlencode({"var-team": team, "var-run": run_id}))


def format_team(team, namespaces, rules, run_id, kinds_text, cfg, cap):
    lines = ["*Gatekeeper daily report: %s* (run %s, %s)" % (team, run_id, kinds_text)]
    for ns in sorted(namespaces):
        stats = namespaces[ns]
        parts = [describe_counts(r, stats[r]) for r in rules if stats.get(r, {}).get("workloads")]
        lines.append("*%s*: %s" % (ns, " · ".join(parts)))
        if cap <= 0:
            continue
        for r in rules:
            s = stats.get(r)
            if not s or not s["workloads"]:
                continue
            shown = ", ".join("`%s`" % n for n in s["names"][:cap])
            more = len(s["names"]) - cap
            lines.append("• %s: %s%s" % (RULE_SHORT.get(r, r), shown, " +%d more" % more if more > 0 else ""))
    lines.append("<%s|Full list in Grafana> · <%s|How to fix or exempt>" % (
        dashboard_link(cfg["dashboard_url"], team, run_id), cfg["readme_url"]))
    return "\n".join(lines)


def fit_message(team, namespaces, rules, run_id, kinds_text, cfg):
    """Names capped at maxNames, then 5, then none; counts and the footer always stay."""
    caps = [cfg["max_names"]] + [c for c in (5, 0) if c < cfg["max_names"]]
    for cap in caps:
        text = format_team(team, namespaces, rules, run_id, kinds_text, cfg, cap)
        if len(text) <= cfg["max_chars"]:
            return text
    return text


def clean_message(team, run_id, kinds_text, cfg):
    return "*Gatekeeper daily report: %s* (run %s, %s)\nNo workload policy violations.\n<%s|Dashboard>" % (
        team, run_id, kinds_text, dashboard_link(cfg["dashboard_url"], team, run_id))


def kinds_text(kinds):
    return " + ".join("%ss" % k for _, k in kinds) or "no workloads"


def parse_time(value):
    return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


def audit_fresh(status, now, created=None):
    """An audit counts when it is under AUDIT_MAX_AGE old and started at least AUDIT_SETTLE
    after the Constraint was created (created: its metadata.creationTimestamp, if known)."""
    ts = status.get("auditTimestamp")
    if not ts or "totalViolations" not in status:
        return False
    try:
        audited = parse_time(ts)
        if created and audited - parse_time(created) < AUDIT_SETTLE:
            return False
        return now - audited < AUDIT_MAX_AGE
    except ValueError:
        return False


def audit_check(constraints_by_kind, findings, now):
    """R6. Every Constraint with a fresh audit (< 2h) is checked on its own: gator count vs
    status.totalViolations. A Constraint without one is skipped (not an error), whatever
    the list order, and named in the Pod log. -> ({rule: {"gator": n, "audit": m} | "skipped"},
    [problem text]), the Loki contract's shapes: gator/audit cover the Constraints with a
    fresh audit, and "skipped" means none of the kind had one."""
    counts = {}
    for f in findings:
        k = (f["constraintKind"], f["constraint"])
        counts[k] = counts.get(k, 0) + 1
    check, problems = {}, []
    for kind, constraints in constraints_by_kind.items():
        total, skipped = {"gator": 0, "audit": 0}, []
        for c in sorted(constraints, key=lambda c: c["metadata"]["name"]):
            name = c["metadata"]["name"]
            status = c.get("status") or {}
            if not audit_fresh(status, now, c["metadata"].get("creationTimestamp")):
                skipped.append(name)
                continue
            gator, audit = counts.get((kind, name), 0), int(status["totalViolations"])
            total["gator"] += gator
            total["audit"] += audit
            if (gator == 0 and audit > 0) or abs(gator - audit) > max(5, audit // 10):
                problems.append("audit check: %s gator %d vs audit %d" % (name, gator, audit))
        if skipped:
            log("audit check: %s: no fresh audit, not compared: %s" % (rule_of(kind), ", ".join(skipped)))
        check[rule_of(kind)] = "skipped" if len(skipped) == len(constraints) else total
    return check, problems


def loki_payload(job, run_id, start_ns, by_team, totals, workloads, teams, run_line):
    """Loki push body (the contract in the README). All lines share the run start time,
    plus 1ns per line so their order is unique."""
    streams = {}
    seq = [0]

    def add(team, namespace, line):
        key = (team, namespace)
        if key not in streams:
            streams[key] = {"stream": {"job": job, "run_id": run_id, "team": team, "namespace": namespace},
                            "values": []}
        streams[key]["values"].append([str(start_ns + seq[0]), json.dumps(line, sort_keys=True)])
        seq[0] += 1

    for team in sorted(by_team):
        for ns in sorted(by_team[team]):
            for rule, s in sorted(by_team[team][ns].items()):
                line = {"type": "summary", "rule": rule, "workloads": s["workloads"]}
                if rule == "mclabels":
                    line.update(missing=s["missing"], invalid=s["invalid"])
                else:
                    line["containers"] = s["containers"]
                add(team, ns, line)
    for (team, rule), t in sorted(totals.items()):
        add(team, "_team", dict(type="team_total", rule=rule, **t))
    for key in sorted(workloads):
        w = workloads[key]
        add(route(w["namespace"], teams), w["namespace"], {
            "type": "violation", "rule": w["rule"], "kind": w["kind"], "workload": w["name"],
            "containers": sorted(w["containers"]),
            "problems": {"missing": sorted(w["missing"]), "invalid": sorted(w["invalid"])},
            "msg": "\n".join(w["msgs"])})
    add("_run", "_run", run_line)
    return {"streams": list(streams.values())}


# ---------------------------------------------------------------------------------------
# I/O
# ---------------------------------------------------------------------------------------

class ClusterSource:
    """GETs from the API server. base: $KUBE_API, or the in-cluster API with the Pod's token."""

    SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

    def __init__(self, base=None, urlopen=urllib.request.urlopen):
        self.urlopen = urlopen
        self.headers = {"Accept": "application/json"}
        self.context = None
        self.in_cluster = not base
        self.base = base.rstrip("/") if base else "https://kubernetes.default.svc"

    def _credentials(self):
        """The Pod's ServiceAccount token and CA, read on first use (errors skip the run)."""
        if self.in_cluster and self.context is None:
            try:
                with open(os.path.join(self.SA_DIR, "token")) as f:
                    self.headers["Authorization"] = "Bearer " + f.read().strip()
                self.context = ssl.create_default_context(cafile=os.path.join(self.SA_DIR, "ca.crt"))
            except (OSError, ssl.SSLError) as e:
                raise ReportError("in-cluster credentials: %s" % e)

    def get(self, path, params=None):
        self._credentials()
        url = self.base + path + ("?" + urllib.parse.urlencode(params) if params else "")
        req = urllib.request.Request(url, headers=self.headers)
        try:
            kwargs = {"timeout": HTTP_TIMEOUT}
            if self.context is not None:
                kwargs["context"] = self.context
            with self.urlopen(req, **kwargs) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 410:
                raise ReportError("GET %s: 410 Gone (list continue token expired)" % path)
            raise ReportError("GET %s: HTTP %d" % (path, e.code))
        except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException) as e:
            raise ReportError("GET %s: %s: %s" % (path, type(e).__name__, redact(getattr(e, "reason", e))))

    def list(self, path):
        """Every item, following metadata.continue (R5)."""
        items, cont = [], None
        while True:
            params = {"limit": PAGE_SIZE}
            if cont:
                params["continue"] = cont
            page = self.get(path, params)
            items.extend(page.get("items") or [])
            cont = (page.get("metadata") or {}).get("continue")
            if not cont:
                return items


class FileSource:
    """Raw API JSON from a directory: "/apis/apps/v1/deployments" -> apis_apps_v1_deployments.json."""

    def __init__(self, directory):
        self.directory = directory

    def get(self, path, params=None):
        name = path.strip("/").replace("/", "_") + ".json"
        try:
            with open(os.path.join(self.directory, name)) as f:
                return json.load(f)
        except (OSError, ValueError) as e:
            raise ReportError("read %s: %s" % (name, e))

    def list(self, path):
        return self.get(path).get("items") or []


def fetch(source, constraint_kinds):
    """-> (projected objects, constraints_by_kind (raw), workload kinds)."""
    objects, constraints_by_kind = [], {}
    for kind in constraint_kinds:
        constraints = source.list("/apis/constraints.gatekeeper.sh/v1beta1/" + kind.lower())
        if not constraints:
            raise ReportError("no %s constraints in the cluster" % kind)
        constraints_by_kind[kind] = constraints
        objects.append(project_template(source.get("/apis/templates.gatekeeper.sh/v1/constrainttemplates/" + kind.lower())))
        objects.extend(project_constraint(c, kind) for c in constraints)
    kinds = matched_workload_kinds([c for cs in constraints_by_kind.values() for c in cs])
    objects.extend(project_namespace(n) for n in source.list("/api/v1/namespaces"))
    for group_kind in kinds:
        api_version, path = WORKLOAD_RESOURCES[group_kind]
        objects.extend(project_workload(i, api_version, group_kind[1]) for i in source.list(path))
    return objects, constraints_by_kind, kinds


def write_inputs(directory, objects):
    """One object per file (R4): gator reads JSON files, and a `kind: List` would be ignored.
    gator reads every file in `directory`, so a reused --work must not feed it the last run's
    objects: the files a previous run wrote are removed first, and any other file stops the run."""
    os.makedirs(directory, exist_ok=True)
    for name in os.listdir(directory):
        if INPUT_FILE_RE.match(name):
            os.remove(os.path.join(directory, name))
    others = sorted(os.listdir(directory))
    if others:
        raise ReportError("%s holds files report.py did not write (%s): use an empty --work"
                          % (directory, ", ".join(others[:3])))
    for i, obj in enumerate(objects):
        with open(os.path.join(directory, "%06d.json" % i), "w") as f:
            json.dump(obj, f)


def run_gator(gator, input_dir, timeout=GATOR_TIMEOUT):
    """gator test -o json -> results. Non-zero exit, a WARNING on stderr, a timeout or
    output that is not JSON -> ReportError."""
    try:
        p = subprocess.run([gator, "test", "-f", input_dir, "-o", "json"], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise ReportError("gator timed out after %ds" % timeout)
    except OSError as e:
        raise ReportError("gator did not start: %s" % e)
    err = p.stderr.decode("utf-8", "replace").strip()
    if p.returncode != 0:
        raise ReportError("gator exited %d: %s" % (p.returncode, (err.splitlines() or [""])[0][:300]))
    if "warning" in err.lower():
        raise ReportError("gator warned: %s" % err.splitlines()[0][:300])
    if err:
        log("gator stderr: " + err[:1000])
    try:
        results = json.loads(p.stdout.decode("utf-8") or "null")
    except ValueError as e:
        raise ReportError("gator output is not JSON: %s" % e)
    if results is not None and not isinstance(results, list):
        raise ReportError("gator output is not a list")
    return results or []


def download_gator(url, sha256, directory, urlopen=urllib.request.urlopen):
    """Download the release tarball, check its sha256, extract only the gator binary."""
    os.makedirs(directory, exist_ok=True)
    tarball = os.path.join(directory, "gator.tar.gz")
    digest = hashlib.sha256()
    try:
        with urlopen(urllib.request.Request(url), timeout=120) as resp, open(tarball, "wb") as out:
            while True:
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                digest.update(chunk)
                out.write(chunk)
    except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException) as e:
        raise ReportError("gator download failed: %s: %s" % (type(e).__name__, hide(getattr(e, "reason", e), url)))
    if digest.hexdigest() != sha256:
        raise ReportError("gator sha256 mismatch: got %s, want %s" % (digest.hexdigest(), sha256))
    path = os.path.join(directory, "gator")
    try:
        with tarfile.open(tarball) as tar:
            member = tar.getmember("gator")
            src = tar.extractfile(member)
            if not member.isfile() or src is None:
                raise ReportError("gator tarball: gator is not a file")
            with open(path, "wb") as out:
                out.write(src.read())
    except (tarfile.TarError, KeyError, OSError) as e:
        raise ReportError("gator tarball: %s" % e)
    os.chmod(path, 0o755)
    os.remove(tarball)
    return path


def post_json(url, body, urlopen=urllib.request.urlopen, slack=False):
    """POST body as JSON. Returns None on success, else a reason without `url` (R3): every
    error text goes through hide(), and a malformed URL (ValueError, http.client.InvalidURL
    quote it) gets a fixed text. slack: the body must also be "ok" (or empty). Never raises
    for an HTTP or network error."""
    try:
        req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                                     headers={"Content-Type": "application/json"}, method="POST")
        with urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            text = resp.read(200).decode("utf-8", "replace").strip()
            if not 200 <= resp.status < 300:
                return "HTTP %d" % resp.status
            if slack and text not in ("", "ok"):
                return "unexpected response %r" % hide(text, url)[:80]
            return None
    except urllib.error.HTTPError as e:
        try:
            text = e.read(200).decode("utf-8", "replace").strip()
        except (OSError, http.client.HTTPException, AttributeError):
            text = ""
        return ("HTTP %d %s" % (e.code, hide(text, url)[:80])).strip()
    except (ValueError, http.client.InvalidURL):
        return "invalid URL"
    except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
        return "%s: %s" % (type(e).__name__, hide(getattr(e, "reason", e), url)[:120])


def post(url, text, urlopen=urllib.request.urlopen):
    """POST {"text": ...} to a webhook. None on success, else a reason without the URL."""
    return post_json(url, {"text": text}, urlopen, slack=True)


def push(url, payload, urlopen=urllib.request.urlopen):
    """POST the Loki payload. None on success, else a reason."""
    return post_json(url, payload, urlopen)


# ---------------------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------------------

def env_config(env):
    def flag(name):
        return env.get(name, "false").strip().lower() == "true"
    return {
        "dry_run": flag("DRY_RUN"),
        "post_when_clean": flag("POST_WHEN_CLEAN"),
        "max_names": int(env.get("MAX_NAMES", "10")),
        "max_chars": int(env.get("MAX_CHARS", "3500")),
        "dashboard_url": env.get("DASHBOARD_URL", "https://grafana.invalid/d/gk-workload-policy"),
        "readme_url": env.get("README_URL", "https://github.com/MapColonies/helm-charts-new/blob/master/charts/gatekeeper-constraints/README.md"),
        "schedule": env.get("SCHEDULE", ""),
        "constraint_kinds": [k for k in env.get("CONSTRAINT_KINDS", "K8sWorkloadCpuRatio,K8sWorkloadMcLabels").split(",") if k],
        "gator_version": env.get("GATOR_VERSION", ""),
        "gator_url": env.get("GATOR_URL", ""),
        "gator_sha256": env.get("GATOR_SHA256", ""),
        "loki_url": env.get("LOKI_URL", ""),
        "loki_job": env.get("LOKI_JOB", "gatekeeper-workload-report"),
    }


class Runner:
    """Holds the I/O hooks so tests can swap them."""

    def __init__(self, cfg, teams, env, source, gator=None, work="/work",
                 urlopen=urllib.request.urlopen, now=None, out=None):
        self.cfg, self.teams, self.env, self.source = cfg, teams, env, source
        self.gator, self.work, self.urlopen, self.out = gator, work, urlopen, out or sys.stdout
        self.now = now or datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        self.run_id = self.now.strftime("%Y-%m-%dT%H:%M:%SZ")
        self.posted, self.failed, self.problems = [], [], []

    def send(self, team, text):
        """Post (or, in a dry run, print) one message. Records the outcome. A team with no
        webhook fails in a dry run too, so a dryRun deploy shows a missing Secret key."""
        env_name = self.teams["webhookEnv"].get(team)
        url = (self.env.get(env_name) or "").strip() if env_name else ""
        if self.cfg["dry_run"]:
            print("--- dry run: message for %s (%s %s)\n%s\n" % (
                team, env_name, "set" if url else "NOT SET", text), file=self.out, flush=True)
        if not url:
            reason = "no webhook (%s is empty)" % env_name
        elif self.cfg["dry_run"]:
            reason = None
        else:
            reason = post(url, text, self.urlopen)
        if reason:
            log("post to %s failed: %s" % (team, reason))
            self.failed.append(team)
            self.problems.append("%s: %s" % (team, reason))
            return False
        log(("dry run, not posted to %s" if self.cfg["dry_run"] else "posted to %s") % team)
        self.posted.append(team)
        return True

    def run(self):
        start_ns = int(self.now.timestamp()) * 10**9
        cfg, rules = self.cfg, [rule_of(k) for k in self.cfg["constraint_kinds"]]
        status, reason, kinds, check = "ok", "", [], {}
        by_team, totals, workloads = {}, {}, {}
        try:
            objects, constraints_by_kind, kinds = fetch(self.source, cfg["constraint_kinds"])
            log("fetched %d objects (%s)" % (len(objects), kinds_text(kinds)))
            gator = self.gator or download_gator(cfg["gator_url"], cfg["gator_sha256"],
                                                 os.path.join(self.work, "bin"), self.urlopen)
            input_dir = os.path.join(self.work, "in")
            write_inputs(input_dir, objects)
            findings = parse_gator(run_gator(gator, input_dir))
            workloads = group_workloads(findings)
            by_team, totals = summarize(workloads, self.teams, rules)
            check, audit_problems = audit_check(constraints_by_kind, findings, self.now)
            for (team, rule), t in sorted(totals.items()):
                if t["workloads"]:
                    log("%s %s: %s" % (team, rule, json.dumps(t, sort_keys=True)))
            log("audit check: %s" % json.dumps(check, sort_keys=True))
        except Exception as e:  # any failure skips the run; infra and Loki are still told
            if isinstance(e, ReportError):
                reason = redact(e)
            else:  # unexpected (a bug, /work not writable, ...): keep the trace in the log
                reason = redact("%s: %s" % (type(e).__name__, e))
                log(redact(traceback.format_exc()))
            status, check = "skipped", dict.fromkeys(rules, "skipped")
            by_team, totals, workloads = {}, {}, {}  # a skipped run pushes its run line only
            log("report skipped: " + reason)
            self.send(self.teams["defaultTeam"], "*Gatekeeper daily report skipped* (run %s): %s" % (self.run_id, reason))
        if status == "ok":
            text = kinds_text(kinds)
            for team in all_teams(self.teams):
                if team == SILENCED:
                    continue  # D8: dashboard only
                if by_team.get(team):
                    self.send(team, fit_message(team, by_team[team], rules, self.run_id, text, cfg))
                elif cfg["post_when_clean"]:
                    self.send(team, clean_message(team, self.run_id, text, cfg))
            problems = audit_problems + ["report partial: " + p for p in self.problems]
            if problems:
                status, reason = "partial", "; ".join(problems)
                self.send(self.teams["defaultTeam"], "*Gatekeeper daily report: problems* (run %s)\n%s" % (
                    self.run_id, "\n".join("• " + p for p in problems)))

        def make_run_line():
            return {"type": "run", "status": status, "reason": reason, "posted": sorted(set(self.posted)),
                    "failed": sorted(set(self.failed)), "dryRun": cfg["dry_run"], "auditCheck": check,
                    "gator": cfg["gator_version"], "schedule": cfg["schedule"]}

        run_line = make_run_line()
        payload = loki_payload(cfg["loki_job"], self.run_id, start_ns, by_team, totals, workloads,
                               self.teams, run_line)
        if cfg["loki_url"]:
            err = push(cfg["loki_url"], payload, self.urlopen)
            if err:
                log("loki push failed: " + err)
                status = "partial" if status == "ok" else status
                reason = "; ".join(x for x in (reason, "loki push failed: " + err) if x)
                self.send(self.teams["defaultTeam"], "*Gatekeeper daily report: problems* (run %s)\n• report partial: loki push failed: %s"
                          % (self.run_id, err))
                run_line = make_run_line()  # the Pod log is the only record of this run now
            else:
                log("pushed %d lines to loki" % sum(len(s["values"]) for s in payload["streams"]))
        else:
            log("LOKI_URL not set: not pushing %d lines" % sum(len(s["values"]) for s in payload["streams"]))
        log("run %s: %s" % (self.run_id, json.dumps(run_line, sort_keys=True)))
        self.status, self.run_line, self.payload = status, run_line, payload
        return 0 if status == "ok" else 1


def main(argv=None, env=None, urlopen=urllib.request.urlopen):
    env = dict(os.environ) if env is None else env
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    src = p.add_argument_group("source").add_mutually_exclusive_group(required=True)
    src.add_argument("--from-cluster", action="store_true", help="read $KUBE_API (default: in-cluster)")
    src.add_argument("--from-files", metavar="DIR", help="read raw API JSON files")
    p.add_argument("--dry-run", action="store_true", help="log messages instead of posting (or DRY_RUN=true)")
    p.add_argument("--teams", required=True, help="teams.json rendered by the chart")
    p.add_argument("--gator", help="gator binary to use instead of downloading GATOR_URL")
    p.add_argument("--work", default="/work",
                   help="scratch directory (default /work); gator reads <work>/in, which must hold only this script's files")
    args = p.parse_args(argv)
    cfg = env_config(env)
    cfg["dry_run"] = cfg["dry_run"] or args.dry_run
    with open(args.teams) as f:
        teams = json.load(f)
    source = FileSource(args.from_files) if args.from_files else ClusterSource(env.get("KUBE_API"))
    return Runner(cfg, teams, env, source, gator=args.gator, work=args.work, urlopen=urlopen).run()


if __name__ == "__main__":
    sys.exit(main())
