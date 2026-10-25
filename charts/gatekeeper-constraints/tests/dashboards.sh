#!/usr/bin/env bash
# Asserts on the rendered dashboard ConfigMap: off by default, sidecar label and folder
# annotation, rendered into dashboards.namespace, valid JSON, fixed uid and datasources,
# and every report query reads the daily report's Loki job and follows its line contract.
set -euo pipefail
cd "$(dirname "$0")/.."

render() { helm template gatekeeper-constraints . -n gatekeeper-system "$@"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
on=(--set dashboards.enabled=true --set dashboards.namespace=infra-dev)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. off by default
out=$(render) || fail "default render failed"
grep -q 'mapcolonies.io/grafana-dashboards' <<<"$out" && fail "default render must not contain the dashboard ConfigMap"

# 2. on: ConfigMap with the sidecar label and folder annotation, in dashboards.namespace
out=$(render "${on[@]}" --show-only templates/dashboards.yaml)
grep -q 'mapcolonies.io/grafana-dashboards: "true"' <<<"$out" || fail "sidecar label missing"
grep -q 'mapcolonies.io/grafana-dashboards-folder: "Gatekeeper"' <<<"$out" || fail "folder annotation must default to Gatekeeper"
grep -q '^  namespace: infra-dev$' <<<"$out" || fail "ConfigMap must be rendered into dashboards.namespace"
grep -q 'namespace: gatekeeper-system' <<<"$out" && fail "ConfigMap must not be in the release namespace"
out=$(render "${on[@]}" --set dashboards.folder=Policies --show-only templates/dashboards.yaml)
grep -q 'mapcolonies.io/grafana-dashboards-folder: "Policies"' <<<"$out" || fail "dashboards.folder not used"

# 3. enabled without a namespace fails loudly
err=$(render --set dashboards.enabled=true 2>&1 || true)
grep -q 'dashboards.namespace is required when dashboards.enabled' <<<"$err" || fail "empty dashboards.namespace must fail"

# 4. dashboard JSON: one key per files/dashboards/*.json, valid JSON, contract checks
render "${on[@]}" --show-only templates/dashboards.yaml >"$tmp/default.yaml"
render "${on[@]}" --set dailyReport.loki.job=custom-job --show-only templates/dashboards.yaml >"$tmp/custom.yaml"
python3 -I - "$tmp/default.yaml" "$tmp/custom.yaml" files/dashboards <<'EOF' || fail "dashboard JSON checks failed (see above)"
import json, os, re, sys

def data_keys(path):
    """The ConfigMap's data block: '  <key>: |-' followed by lines indented 4 spaces."""
    keys, cur = {}, None
    for line in open(path).read().split("\n"):
        m = re.match(r"^  (\S+): \|-$", line)
        if m:
            cur = m.group(1); keys[cur] = []
        elif cur and (line.startswith("    ") or line == ""):
            keys[cur].append(line[4:])
        else:
            cur = None
    return {k: "\n".join(v) for k, v in keys.items()}

errors = []
def check(ok, msg):
    if not ok:
        errors.append(msg)

def walk(node, fn):
    fn(node)
    if isinstance(node, dict):
        for v in node.values():
            walk(v, fn)
    elif isinstance(node, list):
        for v in node:
            walk(v, fn)

files = sorted(f for f in os.listdir(sys.argv[3]) if f.endswith(".json"))
for path, job in ((sys.argv[1], "gatekeeper-workload-report"), (sys.argv[2], "custom-job")):
    data = data_keys(path)
    check(sorted(data) == files, f"data keys {sorted(data)} != files/dashboards {files}")
    for key, text in data.items():
        try:
            dash = json.loads(text)
        except ValueError as e:
            errors.append(f"{key}: invalid JSON: {e}"); continue
        check("__REPORT_JOB__" not in text, f"{key}: __REPORT_JOB__ placeholder left")
        check("__inputs" not in dash and "${DS_" not in text, f"{key}: export-for-sharing inputs are not resolved by the sidecar")
        uids = set()
        walk(dash, lambda n: uids.add(n["datasource"].get("uid")) if isinstance(n, dict) and isinstance(n.get("datasource"), dict) else None)
        check(uids <= {"loki", "${loki_datasource}", "-- Grafana --"}, f"{key}: unexpected datasource uids {uids}")
        if key != "gatekeeper-workload-policy.json":
            continue
        check(dash.get("uid") == "gk-workload-policy", "uid must be gk-workload-policy (the report links to /d/gk-workload-policy)")
        check(dash.get("schemaVersion", 0) >= 39, "schemaVersion must be >= 39 (Grafana 12)")
        ids = [p["id"] for p in dash["panels"]]
        check(len(ids) == len(set(ids)), "panel ids must be unique")
        tv = {v["name"]: v for v in dash["templating"]["list"]}
        check(set(tv) >= {"loki_datasource", "team", "namespace", "run"}, f"variables: {sorted(tv)}")
        check(tv["loki_datasource"]["query"] == "loki" and tv["loki_datasource"]["current"].get("value") == "loki",
              "loki_datasource must default to uid loki")
        sel = '{job="%s"' % job
        check(tv["team"]["query"].startswith("label_values(" + sel) and tv["team"]["regex"] == "/^[^_]/",
              "team variable must read the report job and hide _run")
        check(tv["namespace"]["query"].startswith("label_values(" + sel) and 'team=~"$team"' in tv["namespace"]["query"]
              and tv["namespace"]["regex"] == "/^[^_]/", "namespace variable must be filtered by team and hide _team/_run")
        check(tv["run"]["query"] == 'label_values(%s, namespace="_team"}, run_id)' % sel and tv["run"]["sort"] == 2
              and not tv["run"]["multi"], "run variable: runs with team_total lines only, newest first, single value")
        check(tv["namespace"].get("allValue") == ".+",
              "namespace variable: All must be .+ so namespaces no report run has seen still show (New at deploy)")

        # Every report query, per panel title and refId: scope, outer aggregation, line type, rule and
        # unwrapped field, so each number reads the line it is labelled with. "run": the selected run only.
        # "trend": every run, per-team totals, highest run of the previous 12 h at a 1 h step (runs only
        # happen 04:00-16:00 UTC, so that is the run day: a rerun is counted once, yesterday never mixes in).
        STAT, BAR = "sum(max by (namespace) (max_over_time(", "max by (namespace) (max_over_time("
        TEAM, NS = "max by (team) (max_over_time(", "max by (team, namespace) (max_over_time("
        TOTAL, LOGS = "sum(max by (team) (max_over_time(", "{"
        cols = {"A": ("cpuRatio", "workloads", "CPU workloads"), "B": ("cpuRatio", "containers", "CPU containers"),
                "C": ("mclabels", "workloads", "mclabels workloads"), "D": ("mclabels", "missing", "mclabels missing"),
                "E": ("mclabels", "invalid", "mclabels invalid")}
        expect = {
            ("CPU ratio: workloads", "A"): ("run", STAT, "summary", "cpuRatio", "workloads"),
            ("CPU ratio: containers", "A"): ("run", STAT, "summary", "cpuRatio", "containers"),
            ("mclabels: workloads", "A"): ("run", STAT, "summary", "mclabels", "workloads"),
            ("mclabels: missing", "A"): ("run", STAT, "summary", "mclabels", "missing"),
            ("mclabels: invalid", "A"): ("run", STAT, "summary", "mclabels", "invalid"),
            ("Workloads by namespace and rule", "A"): ("run", BAR, "summary", "cpuRatio", "workloads"),
            ("Workloads by namespace and rule", "B"): ("run", BAR, "summary", "mclabels", "workloads"),
            ("Workloads", "A"): ("run", LOGS, "violation", None, None),
            ("Violation messages", "A"): ("run", LOGS, "violation", None, None),
            ("CPU ratio: workloads per team", "A"): ("trend", TEAM, "team_total", "cpuRatio", "workloads"),
            ("CPU ratio: workloads per team", "B"): ("trend", TOTAL, "team_total", "cpuRatio", "workloads"),
            ("CPU ratio: workloads per team", "C"): ("trend", TOTAL, "team_total", "cpuRatio", "containers"),
            ("mclabels: workloads per team", "A"): ("trend", TEAM, "team_total", "mclabels", "workloads"),
            ("mclabels: workloads per team", "B"): ("trend", TOTAL, "team_total", "mclabels", "workloads"),
            ("mclabels: workloads per team", "C"): ("trend", TOTAL, "team_total", "mclabels", "missing"),
            ("mclabels: workloads per team", "D"): ("trend", TOTAL, "team_total", "mclabels", "invalid"),
        }
        for ref, (rule, field, _) in cols.items():
            expect[("Per team", ref)] = ("run", TEAM, "team_total", rule, field)
            expect[("Per namespace", ref)] = ("run", NS, "summary", rule, field)
        j = 'job="%s"' % job
        per_ns = {j, 'run_id="$run"', 'team=~"$team"', 'namespace=~"$namespace"'}
        selectors = {("run", "summary"): per_ns, ("run", "violation"): per_ns,
                     ("run", "team_total"): {j, 'run_id="$run"', 'namespace="_team"', 'team=~"$team"'},
                     ("trend", "team_total"): {j, 'namespace="_team"', 'team=~"$team"'}}
        # A stat with no line in the filter shows 0 only when a run is selected, else "no run" (never a clean-looking 0).
        no_run_0 = ' or (0 * sum(count_over_time({%s, run_id="$run", namespace="_team"} [$__range])))' % j

        def selector(expr):
            m = re.search(r"\{([^}]*)\}", expr)
            return set(m.group(1).split(", ")) if m else set()

        panels = {p["title"]: p for p in dash["panels"]}
        seen = set()
        for p in dash["panels"]:
            for t in p.get("targets", []):
                title, ref, expr = p["title"], t["refId"], t["expr"]
                where = f"{title} {ref}"
                if "gatekeeper-system" in expr:   # admission lines, not report lines
                    check("count by (resource_namespace, resource_kind, resource_name, constraint_name)" in expr,
                          f"{where}: admission lines must be counted per distinct workload")
                    continue
                check(sel in expr, f"{where}: query must read {sel}}}: {expr}")
                check("sum_over_time" not in expr, f"{where}: never sum lines over time (reruns would add up)")
                if 'team="_run"' in expr:          # run status lines
                    check(selector(expr) == {j, 'team="_run"'}, f"{where}: run lines: {selector(expr)}")
                    check(re.search(r"\| json [^|]*\bstatus\b[^|]*\bfailed\b", expr) is not None,
                          f"{where}: run lines must extract status and failed")
                    continue
                if (title, ref) not in expect:
                    errors.append(f"{where}: report query with no expectation: {expr}"); continue
                seen.add((title, ref))
                scope, prefix, ltype, rule, field = expect[(title, ref)]
                check(expr.startswith(prefix), f"{where}: must start with {prefix}: {expr}")
                check(selector(expr) == selectors[(scope, ltype)],
                      f"{where}: selector {sorted(selector(expr))} != {sorted(selectors[(scope, ltype)])}")
                check(re.findall(r'\| type="(\w+)"', expr) == [ltype], f"{where}: must filter type=\"{ltype}\"")
                check(re.findall(r'\| rule="(\w+)"', expr) == ([rule] if rule else []), f"{where}: must filter rule=\"{rule}\"")
                check(re.findall(r"unwrap (\w+)", expr) == ([field] if field else []), f"{where}: must unwrap {field}")
                if field is None:
                    check(t.get("queryType") == "range", f"{where}: logs query must be a range query")
                    continue
                check(field in re.search(r"\| json ([^|]*)", expr).group(1).replace(",", " ").split(),
                      f"{where}: | json must extract {field}")
                check('| __error__=""' in expr, f"{where}: unwrap must drop parse errors")
                if scope == "run":
                    check(expr.count("[$__range]") == expr.count("[") and t.get("queryType") == "instant",
                          f"{where}: a selected-run number is an instant query over [$__range]")
                else:
                    check(expr.count("[12h]") == 1 and "[" not in expr.replace("[12h]", ""),
                          f"{where}: trend window must be [12h] (the run day)")
                    check(t.get("queryType") == "range" and t.get("step") == "1h" and p.get("interval") == "1h",
                          f"{where}: trend must be a range query at a 1h step")
                    legend = "{{team}}" if prefix == TEAM else "total " + field
                    check(t.get("legendFormat") == legend, f"{where}: legend must be {legend!r}")
                if prefix == STAT:
                    check(expr.endswith(no_run_0) and expr.count("max_over_time") == 1,
                          f"{where}: a stat must fall back to 0 only for a selected run: {expr}")
                    nv = p["fieldConfig"]["defaults"].get("noValue")
                    check(nv == "no run", f"{where}: noValue must be 'no run' (an empty $run must not read as a clean 0), got {nv!r}")
                    steps = p["fieldConfig"]["defaults"]["thresholds"]["steps"]
                    check([s["color"] for s in steps if s["value"] is None] == ["text"],
                          f"{where}: 'no run' must not be coloured green")
                else:
                    check(expr.count("max_over_time") == 1, f"{where}: one max_over_time only: {expr}")
        missing = set(expect) - seen
        check(not missing, f"panels/queries missing: {sorted(missing)}")
        for title in ("Per team", "Per namespace"):
            org = [x for x in panels[title].get("transformations", []) if x["id"] == "organize"]
            names = org[0]["options"]["renameByName"] if org else {}
            want = {"Value #" + ref: col for ref, (_, _, col) in cols.items()}
            check(names == want, f"{title}: column names {names} != {want}")
        org = [x for x in panels["Workloads by namespace and rule"].get("transformations", []) if x["id"] == "organize"]
        check(org and org[0]["options"]["renameByName"] == {"Value #A": "CPU ratio", "Value #B": "mclabels"},
              "Workloads by namespace and rule: A must be named CPU ratio and B mclabels")
        last = panels.get("Last run")
        check(last is not None and last["type"] == "stat", "a 'Last run' stat must show the newest run")
        if last:
            ro = last["options"]["reduceOptions"]
            check(last["targets"][0].get("maxLines") == 1 and ro["calcs"] == ["lastNotNull"],
                  "Last run: newest line only (maxLines 1, lastNotNull)")
            check(ro["fields"] == "/^(status|age|failed teams)$/", f"Last run: must show status, age and failed teams, got {ro['fields']}")
            ov = {o["matcher"]["options"]: {x["id"]: x["value"] for x in o["properties"]} for o in last["fieldConfig"]["overrides"]}
            check(ov.get("Time", {}).get("displayName") == "age" and ov["Time"].get("unit") == "dateTimeFromNow",
                  "Last run: the line time must be shown as age (dateTimeFromNow)")
            check(ov.get("failed", {}).get("displayName") == "failed teams", "Last run: failed must be shown as failed teams")
            check(last["fieldConfig"]["defaults"].get("noValue") == "no run", "Last run: noValue must be 'no run'")
        adm = [t["expr"] for p in dash["panels"] for t in p.get("targets", []) if "gatekeeper-system" in t["expr"]]
        check(len(adm) == 1, f"one admission query expected, got {len(adm)}")
        check(any('team="_run"' in t["expr"] for t in panels.get("Runs", {}).get("targets", [])), "a Runs table must list every run")
for e in errors:
    print("  " + e, file=sys.stderr)
sys.exit(1 if errors else 0)
EOF

echo "OK"
