"""Unit tests for files/daily-report/report.py (stdlib unittest, python3 -I compatible).

  python3 -I -B -m unittest discover -s tests/daily-report -t tests/daily-report

Fixtures: fixtures/api is raw API JSON (list items without kind/apiVersion), and
fixtures/gator-results.json is real gator output for report.py's projection of it (both
written by make-fixtures.sh; parity.sh fails when they are stale). gator itself is
replaced by small shell scripts here; parity.sh runs the real one.
"""

import contextlib
import datetime
import hashlib
import importlib.util
import io
import json
import os
import socket
import stat
import tarfile
import tempfile
import unittest
import urllib.error
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
CHART = os.path.join(HERE, "..", "..")
FIXTURES = os.path.join(HERE, "fixtures")
API = os.path.join(FIXTURES, "api")
GATOR_RESULTS = os.path.join(FIXTURES, "gator-results.json")

spec = importlib.util.spec_from_file_location("report", os.path.join(CHART, "files", "daily-report", "report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

NOW = datetime.datetime(2026, 10, 26, 7, 30, 4, tzinfo=datetime.timezone.utc)
RUN_ID = "2026-10-26T07:30:04Z"
WEBHOOKS = {"RASTER_WEBHOOK": "https://hooks.invalid/services/RASTER-SECRET",
            "VECTOR_WEBHOOK": "https://hooks.invalid/services/VECTOR-SECRET",
            "TEAM_3D_WEBHOOK": "https://hooks.invalid/services/3D-SECRET",
            "INFRA_WEBHOOK": "https://hooks.invalid/services/INFRA-SECRET"}
LOKI = "http://loki.invalid/loki/api/v1/push"
TEAMS = {  # what templates/daily-report.yaml renders for these namespaceTeams
    "entries": [
        {"namespace": "raster-dev", "regex": "raster-dev", "team": "raster"},
        {"namespace": "vector-dev", "regex": "vector-dev", "team": "vector"},
        {"namespace": "3d-dev", "regex": "3d-dev", "team": "3d"},
        {"namespace": "dem-dev", "regex": "dem-dev", "team": "3d"},
        {"namespace": "gateway-dev", "regex": "gateway-dev", "team": None},
    ],
    "defaultTeam": "infra",
    "teams": ["raster", "vector", "3d", "infra"],
    "webhookEnv": {"raster": "RASTER_WEBHOOK", "vector": "VECTOR_WEBHOOK", "3d": "TEAM_3D_WEBHOOK",
                   "infra": "INFRA_WEBHOOK"},
}


def cfg(**over):
    c = report.env_config({"DASHBOARD_URL": "https://grafana.invalid/d/gk-workload-policy",
                           "README_URL": "https://readme.invalid", "GATOR_VERSION": "v3.22.0",
                           "SCHEDULE": "30 7 * * 0-4", "LOKI_URL": LOKI})
    c.update(over)
    return c


def gator_results():
    with open(GATOR_RESULTS) as f:
        return json.load(f)


class FakeResponse:
    def __init__(self, status=200, body=b"ok"):
        self.status, self.body = status, body

    def read(self, n=-1):
        out = self.body if n < 0 else self.body[:n]
        self.body = self.body[len(out):]
        return out

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeUrlopen:
    """Records requests. fail: {url substring: exception or FakeResponse} for that URL."""

    def __init__(self, fail=None):
        self.fail = fail or {}
        self.calls = []

    def __call__(self, req, timeout=None, context=None):
        url = req.full_url
        body = json.loads(req.data.decode()) if req.data else None
        self.calls.append((url, body))
        for key, outcome in self.fail.items():
            if key in url:
                if isinstance(outcome, Exception):
                    raise outcome
                return outcome
        return FakeResponse(204 if url == LOKI else 200, b"" if url == LOKI else b"ok")

    def posts(self):
        """{webhook env name: text} for every webhook post."""
        names = {v: k for k, v in WEBHOOKS.items()}
        return {names[u]: b["text"] for u, b in self.calls if u in names}

    def loki(self):
        return [b for u, b in self.calls if u == LOKI]


class GatorScripts:
    """Fake gator binaries (shell scripts) in a temp dir."""

    def __init__(self, tmp):
        self.tmp = tmp

    def make(self, name, body):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + body + "\n")
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        return path

    def printing(self, path):
        return self.make("gator-ok", 'cat "%s"' % path)


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.gators = GatorScripts(self.tmp)
        self.addCleanup(self._tmp.cleanup)
        self.log = io.StringIO()  # report.log() lines
        quiet = contextlib.redirect_stderr(self.log)
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    def runner(self, c=None, env=None, urlopen=None, gator=None, source=None, teams=None):
        self.urlopen = urlopen or FakeUrlopen()
        self.out = io.StringIO()
        r = report.Runner(c or cfg(), teams or TEAMS, WEBHOOKS if env is None else env,
                          source or report.FileSource(API), gator=gator or self.gators.printing(GATOR_RESULTS),
                          work=os.path.join(self.tmp, "work"), urlopen=self.urlopen, now=NOW, out=self.out)
        return r


class ProjectionTest(Base):
    def test_items_get_kind_and_api_version_and_lose_what_rego_does_not_read(self):
        with open(os.path.join(API, "apis_apps_v1_deployments.json")) as f:
            raw = json.load(f)["items"]
        self.assertNotIn("kind", raw[0])  # raw API list items
        item = next(i for i in raw if i["metadata"]["name"] == "init-bad")
        p = report.project_workload(item, "apps/v1", "Deployment")
        self.assertEqual((p["apiVersion"], p["kind"]), ("apps/v1", "Deployment"))
        self.assertEqual(p["metadata"]["namespace"], "vector-dev")
        self.assertNotIn(report.LAST_APPLIED, p["metadata"].get("annotations", {}))
        self.assertEqual(p["spec"]["template"]["spec"]["initContainers"],
                         [{"name": "migrate", "resources": {"requests": {"cpu": "100m"}, "limits": {"cpu": "1"}}}])
        self.assertEqual(p["spec"]["template"]["metadata"]["labels"]["mapcolonies.io/environment"], "undefined")
        text = json.dumps(p)
        for secret in ("must-not-leave-the-pod", "registry.invalid", "status", "uid"):
            self.assertNotIn(secret, text)

    def test_workload_annotations_kept_for_exemptions(self):
        with open(os.path.join(API, "apis_apps_v1_deployments.json")) as f:
            item = next(i for i in json.load(f)["items"] if i["metadata"]["name"] == "exempt-annotated")
        p = report.project_workload(item, "apps/v1", "Deployment")
        self.assertEqual(p["metadata"]["annotations"], {"mapcolonies.io/exempt-cpu-ratio": "Guaranteed QoS on purpose"})

    def test_constraint_is_forced_to_warn_under_its_own_name(self):
        c = {"metadata": {"name": "workload-cpu-ratio-enforced", "uid": "x"},
             "spec": {"enforcementAction": "deny", "match": {"namespaces": ["prod"]}}, "status": {"totalViolations": 3}}
        p = report.project_constraint(c, "K8sWorkloadCpuRatio")
        self.assertEqual(p, {"apiVersion": "constraints.gatekeeper.sh/v1beta1", "kind": "K8sWorkloadCpuRatio",
                             "metadata": {"name": "workload-cpu-ratio-enforced"},
                             "spec": {"enforcementAction": "warn", "match": {"namespaces": ["prod"]}}})
        self.assertEqual(c["spec"]["enforcementAction"], "deny")  # input untouched

    def test_one_object_per_file_never_a_list(self):
        objects, _, _ = report.fetch(report.FileSource(API), ["K8sWorkloadCpuRatio", "K8sWorkloadMcLabels"])
        d = os.path.join(self.tmp, "in")
        report.write_inputs(d, objects)
        files = sorted(os.listdir(d))
        self.assertEqual(len(files), len(objects))
        kinds = []
        for name in files:
            with open(os.path.join(d, name)) as f:
                obj = json.load(f)
            self.assertIn("apiVersion", obj)
            kinds.append(obj["kind"])
        self.assertNotIn("List", " ".join(kinds))
        # each Constraint exactly once (only the warn copy)
        names = [o["metadata"]["name"] for o in objects if o["kind"].startswith("K8sWorkload")]
        self.assertEqual(sorted(names), ["workload-cpu-ratio-enforced", "workload-cpu-ratio-warn", "workload-mclabels-warn"])
        self.assertTrue(all(o["spec"]["enforcementAction"] == "warn" for o in objects if o["kind"].startswith("K8sWorkload")))

    def test_matched_kinds_come_from_the_constraints(self):
        c = {"metadata": {"name": "c"}, "spec": {"match": {"kinds": [{"apiGroups": ["apps"], "kinds": ["StatefulSet", "Deployment"]}]}}}
        self.assertEqual(report.matched_workload_kinds([c]), [("apps", "Deployment"), ("apps", "StatefulSet")])
        for bad in ([{"apiGroups": ["apps"], "kinds": ["DaemonSet"]}], [{"apiGroups": ["*"], "kinds": ["Deployment"]}], None):
            c["spec"]["match"]["kinds"] = bad
            with self.assertRaises(report.ReportError):
                report.matched_workload_kinds([c])


class PaginationTest(Base):
    def test_follows_continue_until_empty(self):
        pages = {"": {"metadata": {"continue": "tok1"}, "items": [{"n": 1}, {"n": 2}]},
                 "tok1": {"metadata": {"continue": ""}, "items": [{"n": 3}]}}
        seen = []

        def urlopen(req, timeout=None, context=None):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(req.full_url).query)
            seen.append(q)
            return FakeResponse(200, json.dumps(pages[q.get("continue", [""])[0]]).encode())

        src = report.ClusterSource("http://127.0.0.1:1/", urlopen=urlopen)
        self.assertEqual(src.list("/apis/apps/v1/deployments"), [{"n": 1}, {"n": 2}, {"n": 3}])
        self.assertEqual([q["limit"] for q in seen], [["500"], ["500"]])
        self.assertEqual(seen[1]["continue"], ["tok1"])

    def test_410_gone_skips(self):
        def urlopen(req, timeout=None, context=None):
            raise urllib.error.HTTPError(req.full_url, 410, "Gone", {}, None)

        with self.assertRaisesRegex(report.ReportError, "410"):
            report.ClusterSource("http://x", urlopen=urlopen).list("/api/v1/namespaces")


class ParseTest(Base):
    def test_overlapping_warn_and_enforced_count_once(self):
        workloads = report.group_workloads(report.parse_gator(gator_results()))
        overlap = workloads[("cpuRatio", "Deployment", "dem-dev", "overlap")]
        self.assertEqual(overlap["containers"], {"app"})
        self.assertEqual(len(overlap["msgs"]), 1)
        self.assertEqual(workloads[("cpuRatio", "Deployment", "raster-dev", "api")]["containers"], {"app", "sidecar"})
        self.assertEqual(workloads[("cpuRatio", "Deployment", "vector-dev", "init-bad")]["containers"], {"migrate"})
        self.assertEqual(len([k for k in workloads if k[0] == "cpuRatio"]), 4)
        self.assertEqual(len([k for k in workloads if k[0] == "mclabels"]), 4)

    def test_mclabels_missing_vs_invalid(self):
        w = report.group_workloads(report.parse_gator(gator_results()))
        self.assertEqual((w[("mclabels", "Deployment", "raster-dev", "api")]["missing"],
                          w[("mclabels", "Deployment", "raster-dev", "api")]["invalid"]),
                         ({"mapcolonies.io/component", "mapcolonies.io/environment", "mapcolonies.io/owner",
                           "mapcolonies.io/part-of"}, set()))
        both = w[("mclabels", "Deployment", "vector-dev", "init-bad")]
        self.assertEqual(both["missing"], {"mapcolonies.io/component"})
        self.assertEqual(both["invalid"], {"mapcolonies.io/environment", "mapcolonies.io/part-of"})
        self.assertEqual(w[("mclabels", "Deployment", "misc-dev", "m")]["invalid"], {"mapcolonies.io/owner"})
        self.assertEqual(w[("mclabels", "StatefulSet", "raster-dev", "db")]["invalid"], {"mapcolonies.io/component"})

    def test_unknown_problem_text_is_invalid(self):
        msg = "Deployment a/b: Pod template mclabels are missing or invalid: mapcolonies.io/owner (too long), x (missing). To exempt this"
        self.assertEqual(report.parse_mclabels_problems(msg), ({"x"}, {"mapcolonies.io/owner"}))
        self.assertEqual(report.parse_mclabels_problems("something else"), (set(), {"(unparsed)"}))

    def test_rego_message_formats_are_the_ones_parsed(self):
        """Pins rego/workload-*.rego: if a message format changes, update report.py's parsing."""
        with open(os.path.join(CHART, "rego", "workload-mclabels.rego")) as f:
            rego = f.read()
        for fmt in ('"%v %v/%v: Pod template mclabels are missing or invalid: %v. To exempt this workload',
                    'concat(", ", sort(problems))', '"%v (missing)"', '"%v (empty)"',
                    'mapcolonies.io/owner (\\"%v\\" is not one of %v)", [owner, concat(", ", sort(owner_domains))]',
                    '"mapcolonies.io/environment (\\"undefined\\" is not allowed)"'):
            self.assertIn(fmt, rego)
        with open(os.path.join(CHART, "rego", "workload-cpu-ratio.rego")) as f:
            self.assertIn('"%v %v/%v container %q: CPU limit must be exactly 4x', f.read())


class RouteFormatTest(Base):
    def test_first_entry_wins_silenced_and_default(self):
        teams = {"entries": [{"regex": "raster-dev", "team": "raster"}, {"regex": "gateway-dev", "team": None},
                             {"regex": "r.*", "team": "rglob"}, {"regex": ".*-dev", "team": "app"}],
                 "defaultTeam": "infra", "teams": ["raster", "rglob", "app"], "webhookEnv": {}}
        self.assertEqual(report.route("raster-dev", teams), "raster")
        self.assertEqual(report.route("raster-qa", teams), "rglob")
        self.assertEqual(report.route("rx-dev", teams), "rglob")
        self.assertEqual(report.route("gateway-dev", teams), "silenced")
        self.assertEqual(report.route("vector-dev", teams), "app")
        self.assertEqual(report.route("prod", teams), "infra")
        self.assertEqual(report.route("xraster-dev", {"entries": [{"regex": "raster-dev", "team": "r"}],
                                                       "defaultTeam": "infra"}), "infra")

    def stats(self, n):
        return {"ns-dev": {"cpuRatio": {"workloads": n, "containers": n + 1, "missing": 0, "invalid": 0,
                                        "names": sorted("w%02d" % i for i in range(n))}}}

    def test_names_sorted_capped_with_more(self):
        text = report.format_team("t", self.stats(13), ["cpuRatio", "mclabels"], RUN_ID, "Deployments", cfg(), 10)
        self.assertIn("• CPU: `w00`, `w01`, `w02`, `w03`, `w04`, `w05`, `w06`, `w07`, `w08`, `w09` +3 more", text)
        self.assertIn("*ns-dev*: CPU limit not 4x request: 13 workloads (14 containers)", text)
        self.assertNotIn("mclabels", text)
        text = report.format_team("t", self.stats(10), ["cpuRatio"], RUN_ID, "Deployments", cfg(), 10)
        self.assertIn("`w09`\n", text)
        self.assertNotIn("more", text)

    def test_shrinks_to_fit_but_keeps_counts_and_footer(self):
        ns = self.stats(40)
        full = report.format_team("t", ns, ["cpuRatio"], RUN_ID, "Deployments", cfg(), 10)
        for limit, expect in ((len(full), "+30 more"), (len(full) - 1, "+35 more"), (200, None)):
            text = report.fit_message("t", ns, ["cpuRatio"], RUN_ID, "Deployments", cfg(max_chars=limit))
            if expect:
                self.assertIn(expect, text)
            else:
                self.assertNotIn("•", text)
            self.assertIn("40 workloads (41 containers)", text)
            self.assertIn("|Full list in Grafana>", text)

    def test_dashboard_link_carries_team_and_run(self):
        self.assertEqual(report.dashboard_link("https://g/d/x", "3d", RUN_ID),
                         "https://g/d/x?var-team=3d&var-run=2026-10-26T07%3A30%3A04Z")
        self.assertTrue(report.dashboard_link("https://g/d/x?orgId=1", "a", "r").startswith("https://g/d/x?orgId=1&var-team=a"))


class RunTest(Base):
    def test_ok_run_posts_per_team_and_pushes_the_contract(self):
        r = self.runner()
        self.assertEqual(r.run(), 0)
        posts = self.urlopen.posts()
        self.assertEqual(set(posts), {"RASTER_WEBHOOK", "VECTOR_WEBHOOK", "TEAM_3D_WEBHOOK", "INFRA_WEBHOOK"})
        raster = posts["RASTER_WEBHOOK"]
        self.assertIn("*Gatekeeper daily report: raster* (run %s, Deployments + StatefulSets)" % RUN_ID, raster)
        self.assertIn("*raster-dev*: CPU limit not 4x request: 1 workloads (2 containers) · "
                      "mclabels: 2 workloads (missing 1, invalid 1)", raster)
        self.assertIn("• mclabels: `api`, `sts/db`", raster)
        self.assertNotIn("exempt-", raster)
        self.assertIn("*dem-dev*: CPU limit not 4x request: 1 workloads (1 containers)", posts["TEAM_3D_WEBHOOK"])
        self.assertIn("*misc-dev*", posts["INFRA_WEBHOOK"])  # unmatched -> defaultTeam
        self.assertNotIn("gateway-dev", "".join(posts.values()))  # D8: silenced, not in Slack
        self.assertIn("mclabels: 1 workloads (missing 1, invalid 1)", posts["VECTOR_WEBHOOK"])

        (payload,) = self.urlopen.loki()
        streams = {(s["stream"]["team"], s["stream"]["namespace"]): s for s in payload["streams"]}
        for s in payload["streams"]:
            self.assertEqual(set(s["stream"]), {"job", "run_id", "team", "namespace"})
            self.assertEqual((s["stream"]["job"], s["stream"]["run_id"]), ("gatekeeper-workload-report", RUN_ID))
        lines = [json.loads(v[1]) for s in payload["streams"] for v in s["values"]]
        ts = sorted(int(v[0]) for s in payload["streams"] for v in s["values"])
        self.assertEqual(len(set(ts)), len(ts))
        self.assertEqual(ts[0], int(NOW.timestamp()) * 10**9)
        # team_total per (team, rule), zeros included, for every team + silenced
        totals = {(s["stream"]["team"], json.loads(v[1])["rule"]): json.loads(v[1])
                  for s in payload["streams"] if s["stream"]["namespace"] == "_team" for v in s["values"]}
        self.assertEqual(set(totals), {(t, r) for t in ("raster", "vector", "3d", "infra", "silenced")
                                       for r in ("cpuRatio", "mclabels")})
        self.assertEqual(totals[("3d", "mclabels")],
                         {"type": "team_total", "rule": "mclabels", "workloads": 0, "containers": 0, "missing": 0, "invalid": 0})
        self.assertEqual(totals[("silenced", "cpuRatio")]["workloads"], 1)
        self.assertEqual(totals[("raster", "cpuRatio")]["containers"], 2)
        # per-namespace summary lines, silenced included (D8: on the dashboard)
        summary = [json.loads(v[1]) for v in streams[("silenced", "gateway-dev")]["values"]]
        self.assertIn({"type": "summary", "rule": "cpuRatio", "workloads": 1, "containers": 1}, summary)
        mcl = [json.loads(v[1]) for v in streams[("raster", "raster-dev")]["values"]
               if json.loads(v[1])["type"] == "summary" and json.loads(v[1])["rule"] == "mclabels"]
        self.assertEqual(mcl, [{"type": "summary", "rule": "mclabels", "workloads": 2, "missing": 1, "invalid": 1}])
        v = [l for l in lines if l["type"] == "violation" and l["workload"] == "init-bad" and l["rule"] == "mclabels"]
        self.assertEqual(v[0]["problems"], {"missing": ["mapcolonies.io/component"],
                                            "invalid": ["mapcolonies.io/environment", "mapcolonies.io/part-of"]})
        self.assertEqual(v[0]["kind"], "Deployment")
        self.assertIn("Pod template mclabels", v[0]["msg"])
        (run,) = [json.loads(x[1]) for x in streams[("_run", "_run")]["values"]]
        self.assertEqual(run, {"type": "run", "status": "ok", "reason": "", "posted": ["3d", "infra", "raster", "vector"],
                               "failed": [], "dryRun": False, "gator": "v3.22.0", "schedule": "30 7 * * 0-4",
                               "auditCheck": {"cpuRatio": {"gator": 6, "audit": 6}, "mclabels": {"gator": 4, "audit": 4}}})

    def test_missing_webhook_fails_that_team_only(self):
        env = dict(WEBHOOKS, VECTOR_WEBHOOK="")
        r = self.runner(env=env)
        self.assertEqual(r.run(), 1)
        posts = self.urlopen.posts()
        self.assertIn("RASTER_WEBHOOK", posts)
        self.assertIn("TEAM_3D_WEBHOOK", posts)
        self.assertEqual(r.run_line["status"], "partial")
        self.assertEqual(r.run_line["failed"], ["vector"])
        infra = [b["text"] for u, b in self.urlopen.calls if u == WEBHOOKS["INFRA_WEBHOOK"]]
        self.assertTrue(any("report partial: vector: no webhook (VECTOR_WEBHOOK is empty)" in t for t in infra))

    def test_every_delivery_failure_is_a_team_failure_without_the_url(self):
        failures = {
            "http 500": urllib.error.HTTPError(WEBHOOKS["RASTER_WEBHOOK"], 500, "x", {}, io.BytesIO(b"no_service")),
            "url error": urllib.error.URLError("Name or service not known"),
            "timeout": socket.timeout("timed out"),
            "slack error body": FakeResponse(200, b"invalid_payload"),
            "non-2xx response": FakeResponse(302, b""),
        }
        for label, outcome in failures.items():
            with self.subTest(label):
                r = self.runner(urlopen=FakeUrlopen({"RASTER-SECRET": outcome}))
                self.assertEqual(r.run(), 1)
                self.assertEqual(r.run_line["status"], "partial")
                self.assertEqual(r.run_line["failed"], ["raster"])
                self.assertEqual(sorted(r.run_line["posted"]), ["3d", "infra", "vector"])
                infra = [b["text"] for u, b in self.urlopen.calls if u == WEBHOOKS["INFRA_WEBHOOK"]]
                self.assertTrue(any("report partial: raster: " in t for t in infra), infra)
                everything = json.dumps(self.urlopen.calls[-1]) + json.dumps(r.run_line) + json.dumps(infra)
                self.assertNotIn("RASTER-SECRET", everything)

    def test_dry_run_posts_nothing_but_still_pushes(self):
        r = self.runner(c=cfg(dry_run=True))
        self.assertEqual(r.run(), 0)
        self.assertEqual(self.urlopen.posts(), {})
        self.assertEqual(len(self.urlopen.loki()), 1)
        self.assertIn("--- dry run: message for raster (RASTER_WEBHOOK set)", self.out.getvalue())
        self.assertTrue(r.run_line["dryRun"])

    def test_post_when_clean(self):
        teams = dict(TEAMS, teams=TEAMS["teams"] + ["app"], webhookEnv=dict(TEAMS["webhookEnv"], app="APP_WEBHOOK"))
        env = dict(WEBHOOKS, APP_WEBHOOK="https://hooks.invalid/services/APP-SECRET")
        r = self.runner(teams=teams, env=env)
        r.run()
        self.assertNotIn("https://hooks.invalid/services/APP-SECRET", [u for u, _ in self.urlopen.calls])
        r = self.runner(c=cfg(post_when_clean=True), teams=teams, env=env)
        r.run()
        clean = [b["text"] for u, b in self.urlopen.calls if u == "https://hooks.invalid/services/APP-SECRET"]
        self.assertEqual(len(clean), 1)
        self.assertIn("No workload policy violations", clean[0])

    def assert_skipped(self, r, reason_re):
        self.assertEqual(r.run(), 1)
        self.assertEqual(r.run_line["status"], "skipped")
        self.assertRegex(r.run_line["reason"], reason_re)
        posts = self.urlopen.posts()
        self.assertEqual(list(posts), ["INFRA_WEBHOOK"])
        self.assertIn("*Gatekeeper daily report skipped*", posts["INFRA_WEBHOOK"])
        (payload,) = self.urlopen.loki()
        self.assertEqual([s["stream"]["team"] for s in payload["streams"]], ["_run"])

    def test_gator_failures_skip(self):
        cases = {
            "exit": ('echo "auditing objects: bad" >&2; exit 1', "gator exited 1: auditing objects: bad"),
            "warning": ('echo "WARNING: something" >&2; echo null', "gator warned"),
            "bad json": ("echo '[{'", "not JSON"),
            "not a list": ("echo '{}'", "not a list"),
        }
        for label, (body, reason) in cases.items():
            with self.subTest(label):
                self.assert_skipped(self.runner(gator=self.gators.make("g-" + label.replace(" ", "-"), body)), reason)

    def test_gator_timeout(self):
        with self.assertRaisesRegex(report.ReportError, "timed out"):
            report.run_gator(self.gators.make("slow", "sleep 5"), self.tmp, timeout=1)

    def test_gator_gets_no_stdin(self):
        # gator reads stdin when given no objects; a stdin left open would hang the job.
        g = self.gators.make("stdin", 'if [ -t 0 ] || ! IFS= read -r x; then echo null; else echo "stdin: $x"; exit 1; fi')
        self.assertEqual(report.run_gator(g, self.tmp), [])

    def test_no_constraints_of_a_configured_kind_skips(self):
        src = report.FileSource(API)
        orig = src.list
        src.list = lambda path: [] if path.endswith("k8sworkloadmclabels") else orig(path)
        self.assert_skipped(self.runner(source=src), "no K8sWorkloadMcLabels constraints")

    def test_audit_mismatch_is_partial_and_tells_infra(self):
        results = gator_results()
        results = [x for x in results if x["constraint"]["metadata"]["name"] != "workload-mclabels-warn"]
        path = os.path.join(self.tmp, "fewer.json")
        with open(path, "w") as f:
            json.dump(results, f)
        r = self.runner(gator=self.gators.make("fewer", 'cat "%s"' % path))
        self.assertEqual(r.run(), 1)
        self.assertEqual(r.run_line["status"], "partial")
        self.assertEqual(r.run_line["auditCheck"]["mclabels"], {"gator": 0, "audit": 4})
        self.assertIn("audit check: workload-mclabels-warn gator 0 vs audit 4", self.urlopen.posts()["INFRA_WEBHOOK"])

    def test_audit_within_tolerance_and_stale_audit(self):
        cs = {"K8sWorkloadCpuRatio": [{"metadata": {"name": "c"}, "status": {"auditTimestamp": "2026-10-26T07:00:00Z",
                                                                             "totalViolations": 150}}]}
        f = [{"constraintKind": "K8sWorkloadCpuRatio", "constraint": "c"}] * 140
        self.assertEqual(report.audit_check(cs, f, NOW), ({"cpuRatio": {"gator": 140, "audit": 150}}, []))
        self.assertEqual(len(report.audit_check(cs, f[:134], NOW)[1]), 1)  # 16 > max(5, 15)
        cs["K8sWorkloadCpuRatio"][0]["status"]["auditTimestamp"] = "2026-10-26T05:00:00Z"
        self.assertEqual(report.audit_check(cs, [], NOW), ({"cpuRatio": "skipped"}, []))

    def test_stale_audit_is_recorded_not_an_error(self):
        r = self.runner()
        r.now = NOW + datetime.timedelta(hours=3)
        self.assertEqual(r.run(), 0)
        self.assertEqual(r.run_line["auditCheck"], {"cpuRatio": "skipped", "mclabels": "skipped"})

    def test_loki_push_failure_is_partial(self):
        r = self.runner(urlopen=FakeUrlopen({LOKI: urllib.error.URLError("connection refused")}))
        self.assertEqual(r.run(), 1)
        self.assertEqual(r.status, "partial")
        self.assertIn("loki push failed", self.urlopen.posts()["INFRA_WEBHOOK"])


class GatorDownloadTest(Base):
    def tarball(self, content=b"#!/bin/sh\necho null\n"):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            info = tarfile.TarInfo("gator")
            info.size, info.mode = len(content), 0o755
            tar.addfile(info, io.BytesIO(content))
        return buf.getvalue()

    def test_checks_sha256_and_extracts_only_gator(self):
        data = self.tarball()
        urlopen = lambda req, timeout=None: FakeResponse(200, data)
        path = report.download_gator("https://x/gator.tar.gz", hashlib.sha256(data).hexdigest(), self.tmp, urlopen)
        self.assertEqual(path, os.path.join(self.tmp, "gator"))
        self.assertTrue(os.access(path, os.X_OK))
        self.assertEqual(report.run_gator(path, self.tmp), [])

    def test_sha256_mismatch_skips(self):
        data = self.tarball()
        urlopen = lambda req, timeout=None: FakeResponse(200, data)
        with self.assertRaisesRegex(report.ReportError, "sha256 mismatch"):
            report.download_gator("https://x/gator.tar.gz", "0" * 64, self.tmp, urlopen)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "gator")))

    def test_download_error_has_no_url(self):
        def urlopen(req, timeout=None):
            raise urllib.error.URLError("https://mirror.invalid/secret-path unreachable")
        with self.assertRaises(report.ReportError) as e:
            report.download_gator("https://mirror.invalid/secret-path", "0" * 64, self.tmp, urlopen)
        self.assertNotIn("secret-path", str(e.exception))


class MainTest(Base):
    def test_cli_from_files_dry_run(self):
        teams = os.path.join(self.tmp, "teams.json")
        with open(teams, "w") as f:
            json.dump(TEAMS, f)
        env = {"DRY_RUN": "false", "GATOR_VERSION": "v3.22.0"}
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = report.main(["--from-files", API, "--dry-run", "--teams", teams, "--work", os.path.join(self.tmp, "w"),
                              "--gator", self.gators.printing(GATOR_RESULTS)], env=env)
        self.assertEqual(rc, 0)
        self.assertIn("--- dry run: message for vector (VECTOR_WEBHOOK NOT SET)", out.getvalue())


if __name__ == "__main__":
    unittest.main()
