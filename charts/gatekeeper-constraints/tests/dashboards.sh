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
        check(tv["team"].get("allValue") == ".+",
              "team variable: All must be .+, else with no run in the dashboard range All matches nothing and the 14-day trend is empty")
        # Datasource: a variable, panel or target without one falls back to Grafana's default datasource
        # (Prometheus on grafana-dev), where the LogQL fails: no options, an empty $run, every panel empty.
        loki_ds = {"type": "loki", "uid": "${loki_datasource}"}
        qvars = [v for v in dash["templating"]["list"] if v.get("type") == "query"]
        check(sorted(v["name"] for v in qvars) == ["namespace", "run", "team"], f"query variables: {[v['name'] for v in qvars]}")
        for v in qvars:
            check(v.get("datasource") == loki_ds, f"variable {v['name']}: datasource must be {loki_ds}, got {v.get('datasource')}")
            check(v.get("refresh") in (1, 2), f"variable {v['name']}: refresh must be 1 or 2 (query the options on load), got {v.get('refresh')}")
        check(tv["run"].get("includeAll") is False, 'run variable must not offer All (run_id="$run" selects one run)')

        # Every report query, per panel title and refId: scope, outer aggregation, line type, rule and
        # unwrapped field, so each number reads the line it is labelled with. "run": the selected run only.
        # "trend": every run, per-team totals as daily bars: the LAST run of each UTC day per team (1d window,
        # 1d step). Every run is its own stream (run_id), so the grouping must be last_over_time(...) by (team):
        # max by (team) over the streams would pick the larger of a rerun, not the later one.
        # "latest": the newest run per team over the panel range (instant), so today's run shows before its
        # bar does (Loki puts a day's point at the next UTC midnight, after now until the day is over).
        STAT, BAR = "sum(max by (namespace) (max_over_time(", "max by (namespace) (max_over_time("
        TEAM, NS = "max by (team) (max_over_time(", "max by (team, namespace) (max_over_time("
        TOTAL, LOGS = "sum(max by (team) (max_over_time(", "{"
        DAY, DAY_TOTAL = "last_over_time(", "sum(last_over_time("
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
            ("CPU ratio: workloads per team", "A"): ("trend", DAY, "team_total", "cpuRatio", "workloads"),
            ("CPU ratio: workloads per team", "B"): ("trend", DAY_TOTAL, "team_total", "cpuRatio", "workloads"),
            ("CPU ratio: workloads per team", "C"): ("trend", DAY_TOTAL, "team_total", "cpuRatio", "containers"),
            ("CPU ratio: workloads per team", "L"): ("latest", DAY, "team_total", "cpuRatio", "workloads"),
            ("mclabels: workloads per team", "A"): ("trend", DAY, "team_total", "mclabels", "workloads"),
            ("mclabels: workloads per team", "B"): ("trend", DAY_TOTAL, "team_total", "mclabels", "workloads"),
            ("mclabels: workloads per team", "C"): ("trend", DAY_TOTAL, "team_total", "mclabels", "missing"),
            ("mclabels: workloads per team", "D"): ("trend", DAY_TOTAL, "team_total", "mclabels", "invalid"),
            ("mclabels: workloads per team", "L"): ("latest", DAY, "team_total", "mclabels", "workloads"),
        }
        for ref, (rule, field, _) in cols.items():
            expect[("Per team", ref)] = ("run", TEAM, "team_total", rule, field)
            expect[("Per namespace", ref)] = ("run", NS, "summary", rule, field)
        j = 'job="%s"' % job
        per_ns = {j, 'run_id="$run"', 'team=~"$team"', 'namespace=~"$namespace"'}
        selectors = {("run", "summary"): per_ns, ("run", "violation"): per_ns,
                     ("run", "team_total"): {j, 'run_id="$run"', 'namespace="_team"', 'team=~"$team"'},
                     ("trend", "team_total"): {j, 'namespace="_team"', 'team=~"$team"'},
                     ("latest", "team_total"): {j, 'namespace="_team"', 'team=~"$team"'}}
        # A stat with no line in the filter shows 0 only when a run is selected, else "no run" (never a clean-looking 0).
        no_run_0 = ' or (0 * sum(count_over_time({%s, run_id="$run", namespace="_team"} [$__range])))' % j
        ns_0 = (' or (0 * count by (team, namespace) (count_over_time({%s, run_id="$run", team=~"$team", namespace=~"$namespace"}'
                ' | json type | type="summary" [$__range])))' % j)
        # New at deploy: distinct workloads per namespace and rule over the previous 24 h. Grouped by
        # constraint_kind, not constraint_name, so a workload hit by both <rule>-warn and <rule>-enforced
        # (a namespace in both lists) counts once.
        ADMISSION = ('count by (resource_namespace, constraint_kind) (count by (resource_namespace, resource_kind, '
                     'resource_name, constraint_kind) (count_over_time({k8s_namespace_name="gatekeeper-system"} '
                     '| json process, event_type, constraint_kind, constraint_name, resource_namespace, resource_kind, '
                     'resource_name | process="admission" | event_type="violation" | constraint_name=~"workload-.*" '
                     '| resource_namespace=~"$namespace" [1d])))')

        def selector(expr):
            m = re.search(r"\{([^}]*)\}", expr)
            return set(m.group(1).split(", ")) if m else set()

        panels = {p["title"]: p for p in dash["panels"]}
        types = {"CPU ratio: workloads": "stat", "CPU ratio: containers": "stat", "mclabels: workloads": "stat",
                 "mclabels: missing": "stat", "mclabels: invalid": "stat", "Last run": "stat", "Per team": "table",
                 "Per namespace": "table", "Workloads by namespace and rule": "barchart", "Workloads": "table",
                 "Trend": "row", "": "text", "CPU ratio: workloads per team": "timeseries",
                 "mclabels: workloads per team": "timeseries", "New at deploy: distinct workloads, previous 24 h": "timeseries",
                 "Runs": "table", "Violation messages": "logs", "About": "text"}
        got_types = {p["title"]: p["type"] for p in dash["panels"]}
        check(len(dash["panels"]) == len(types) and got_types == types,
              f"panel types: {sorted(set(got_types.items()) ^ set(types.items()))} differ from the expected types")
        check(panels["Workloads by namespace and rule"].get("options", {}).get("xField") == "namespace",
              "Workloads by namespace and rule: xField must be namespace (the queries are max by (namespace))")
        seen = set()
        for p in dash["panels"]:
            for t in p.get("targets", []):
                title, ref, expr = p["title"], t["refId"], t["expr"]
                where = f"{title} {ref}"
                if "gatekeeper-system" in expr:   # admission lines, not report lines
                    check(expr == ADMISSION, f"{where}: admission query must be exactly\n    {ADMISSION}\n  got\n    {expr}")
                    check(t.get("legendFormat") == "{{resource_namespace}} {{constraint_kind}}",
                          f"{where}: legend must be per namespace and rule (constraint_kind)")
                    check(t.get("queryType") == "range" and t.get("step") == "1h" and p.get("interval") == "1h",
                          f"{where}: admission panel must be a range query at a 1h step")
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
                if prefix == NS:
                    # A rule with no summary line in a namespace that has one for another rule reads 0, not an
                    # empty cell (Grafana's noValue does not fill cells the merge transform leaves empty).
                    check(expr.endswith(ns_0), f"{where}: must end with the per-namespace 0 fill {ns_0}: {expr}")
                    expr = expr[:-len(ns_0)] if expr.endswith(ns_0) else expr
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
                elif scope == "trend":
                    # The last run of each UTC day per team: window = step = 1d, grouped by team on the range
                    # aggregation itself (not max by (team) over the run_id streams), summed only for totals.
                    tail = "[1d]) by (team)" + (")" if prefix == DAY_TOTAL else "")
                    check(expr.endswith(tail) and expr.count("[") == 1,
                          f"{where}: trend must end with {tail!r} (last run of the day per team): {expr}")
                    check(t.get("queryType") == "range" and t.get("step") == "1d" and p.get("interval") == "1d",
                          f"{where}: trend must be a range query at a 1d step (one bar per UTC day)")
                    legend = "{{team}}" if prefix == DAY else "total " + field
                    check(t.get("legendFormat") == legend, f"{where}: legend must be {legend!r}")
                else:
                    check(expr.endswith("[$__range]) by (team)") and expr.count("[") == 1 and t.get("queryType") == "instant",
                          f"{where}: latest run must be an instant last_over_time(...[$__range]) by (team): {expr}")
                    check(t.get("legendFormat") == "{{team}} latest run", f"{where}: legend must be '{{{{team}}}} latest run'")
                if prefix == STAT:
                    check(expr.endswith(no_run_0) and expr.count("max_over_time") == 1,
                          f"{where}: a stat must fall back to 0 only for a selected run: {expr}")
                    nv = p["fieldConfig"]["defaults"].get("noValue")
                    check(nv == "no run", f"{where}: noValue must be 'no run' (an empty $run must not read as a clean 0), got {nv!r}")
                    steps = p["fieldConfig"]["defaults"]["thresholds"]["steps"]
                    check([s["color"] for s in steps if s["value"] is None] == ["text"],
                          f"{where}: 'no run' must not be coloured green")
                elif scope in ("trend", "latest"):
                    check(expr.count("last_over_time") == 1 and "max" not in expr,
                          f"{where}: one last_over_time and no max (a rerun replaces, it does not keep the larger): {expr}")
                else:
                    check(expr.count("max_over_time") == 1, f"{where}: one max_over_time only: {expr}")
        missing = set(expect) - seen
        check(not missing, f"panels/queries missing: {sorted(missing)}")
        for title in ("Per team", "Per namespace"):
            org = [x for x in panels[title].get("transformations", []) if x["id"] == "organize"]
            names = org[0]["options"]["renameByName"] if org else {}
            want = {"Value #" + ref: col for ref, (_, _, col) in cols.items()}
            check(names == want, f"{title}: column names {names} != {want}")
        # One table: merge first (else Grafana shows one frame per query with a frame picker), then organize,
        # with the key columns shown.
        for title, keys in (("Per team", {"team"}), ("Per namespace", {"team", "namespace"}),
                            ("Workloads by namespace and rule", {"namespace"})):
            tr = panels[title].get("transformations", [])
            ids = [x["id"] for x in tr]
            check(ids[:2] == ["merge", "organize"], f"{title}: transformations must start with merge, organize, got {ids}")
            org = next((x["options"] for x in tr if x["id"] == "organize"), {})
            hidden = {k for k, v in org.get("excludeByName", {}).items() if v} & keys
            check(not hidden, f"{title}: key columns hidden: {sorted(hidden)}")
            if panels[title]["type"] == "table":
                check(keys <= set(org.get("indexByName", {})), f"{title}: key columns {sorted(keys)} must be placed (indexByName)")
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

        for p in dash["panels"]:
            if p.get("targets"):
                check(p.get("datasource") == loki_ds, f"{p['title']}: panel datasource must be {loki_ds}, got {p.get('datasource')}")
                for t in p["targets"]:
                    check(t.get("datasource", loki_ds) == loki_ds, f"{p['title']} {t['refId']}: target datasource must be {loki_ds}")

        # Time ranges: the dashboard default is the Loki retention, 14 days. The Slack link carries only
        # var-team and var-run, and a selected-run query reads [$__range] up to now, so a shorter default
        # turns the link of any retained run older than it into "no run". It also scopes the run variable,
        # Last run and Runs. The trend and New at deploy panels always show the last 14 days; every other
        # panel follows the dashboard range.
        check(dash.get("time") == {"from": "now-14d", "to": "now"},
              f"default time range must be now-14d..now (the Loki retention, so every retained run's link works), got {dash.get('time')}")
        fourteen = {title for (title, _), v in expect.items() if v[0] == "trend"}
        fourteen |= {p["title"] for p in dash["panels"] for t in p.get("targets", []) if "gatekeeper-system" in t["expr"]}
        check(len(fourteen) == 3, f"expected 2 trend panels and New at deploy, got {sorted(fourteen)}")
        for p in dash["panels"]:
            want = "14d" if p["title"] in fourteen else None
            check(p.get("timeFrom") == want, f"{p['title']}: timeFrom must be {want!r}, got {p.get('timeFrom')!r}")
        for name in ("team", "namespace"):
            check(tv[name].get("multi") is True and tv[name].get("includeAll") is True,
                  f"{name} variable must be multi-select with All")

        # Trend: teams are stacked, the dashed totals are not (else the top line reads twice the backlog).
        for title in sorted(fourteen):
            p = panels[title]
            check(p["fieldConfig"]["defaults"]["custom"]["stacking"]["mode"] == "normal", f"{title}: series must be stacked")
            if "gatekeeper-system" in p["targets"][0]["expr"]:
                continue
            ov = [o for o in p["fieldConfig"].get("overrides", []) if o["matcher"] == {"id": "byRegexp", "options": "^total.*"}]
            props = {x["id"]: x["value"] for x in ov[0]["properties"]} if ov else {}
            check(props.get("custom.stacking", {}).get("mode") == "none",
                  f"{title}: an override matching ^total.* must set custom.stacking mode none")
            totals = [t["legendFormat"] for t in p["targets"] if t["refId"] not in ("A", "L")]
            check(totals and all(re.match(r"^total", x) for x in totals), f"{title}: total legends {totals} must match ^total.*")
            # Daily bars, each drawn ending at its point: Loki puts the last run of day D at D+1 00:00 UTC, so
            # barAlignment -1 puts the bar on day D (0 would straddle two days, 1 would draw it on D+1).
            custom = p["fieldConfig"]["defaults"]["custom"]
            check(custom.get("drawStyle") == "bars" and custom.get("barAlignment") == -1,
                  f"{title}: must be bars with barAlignment -1, got {custom.get('drawStyle')!r}, {custom.get('barAlignment')!r}")
            # Latest run: Grafana's Loki datasource returns an instant result as one table (Time, team, Value #L),
            # so it is split per team, then drawn as dots in their own stack (an override by refId no longer
            # matches after the split; Grafana anchors the regexp, hence the trailing .*).
            check([t["refId"] for t in p["targets"]].count("L") == 1, f"{title}: needs one latest-run target (refId L)")
            check(p.get("transformations") == [{"id": "partitionByValues", "filter": {"id": "byRefId", "options": "L"},
                                                 "options": {"fields": ["team"], "keepFields": False, "naming": {"asLabels": True}}}],
                  f"{title}: the latest-run table must be split per team (partitionByValues on team, refId L only)")
            ov = [o for o in p["fieldConfig"].get("overrides", []) if o["matcher"] == {"id": "byRegexp", "options": "Value #L.*"}]
            props = {x["id"]: x["value"] for x in ov[0]["properties"]} if ov else {}
            check(props.get("custom.drawStyle") == "points" and props.get("custom.showPoints") == "always",
                  f"{title}: the latest-run series (override Value #L.*) must be drawn as points")
            check(props.get("custom.stacking", {}).get("mode") == "normal" and props["custom.stacking"].get("group") != "A",
                  f"{title}: latest-run dots must stack in their own group, not on top of the bars")
            check(props.get("displayName") == "${__field.labels.team} latest run" and props.get("custom.hideFrom", {}).get("tooltip") is False,
                  f"{title}: latest-run dots must be named '<team> latest run' and shown in the tooltip")

        # Per team / Per namespace: full width, so every column (the mclabels missing/invalid split too) is
        # visible without scrolling; an empty table must not read as a clean 0.
        for title in ("Per team", "Per namespace"):
            p = panels[title]
            check(p["gridPos"]["w"] == 24, f"{title}: must be full width (w 24), got w {p['gridPos']['w']}")
            check(p["fieldConfig"]["defaults"].get("noValue") is None, f"{title}: an empty table must not read as 0")

        def json_fields(expr):
            m = re.search(r"\| json ([^|]*)", expr)
            return [x.strip() for x in m.group(1).split(",")] if m else []

        # Workloads: the per-workload list the Slack message links to. Never truncated below one run,
        # every column extracted and shown.
        t = panels["Workloads"]["targets"][0]
        check(t.get("maxLines", 0) >= 5000, f"Workloads: maxLines must be >= 5000 (one run has ~300 violation lines), got {t.get('maxLines')}")
        cols_wl = ["type", "rule", "kind", "workload", "containers", 'missing="problems.missing"', 'invalid="problems.invalid"']
        check(json_fields(t["expr"]) == cols_wl, f"Workloads: | json must extract {cols_wl}, got {json_fields(t['expr'])}")
        tr = {x["id"]: x["options"] for x in panels["Workloads"].get("transformations", [])}
        check(tr.get("extractFields", {}).get("source") == "labels", "Workloads: needs an extractFields transform on labels")
        org = tr.get("organize", {})
        shown = {"team", "namespace", "rule", "kind", "workload", "containers", "missing", "invalid"}
        check(set(org.get("indexByName", {})) == shown, f"Workloads: columns {sorted(org.get('indexByName', {}))} != {sorted(shown)}")
        hidden = {k for k, v in org.get("excludeByName", {}).items() if v} & shown
        check(not hidden, f"Workloads: columns hidden: {sorted(hidden)}")
        t = panels["Violation messages"]["targets"][0]
        check(t["expr"].endswith('| json type, msg | type="violation" | line_format "{{.msg}}"') and t.get("maxLines", 0) >= 5000,
              "Violation messages: must show the full msg of every violation line (line_format {{.msg}}, maxLines >= 5000)")

        # Run status: ok green, partial orange, skipped red, on the newest run (Last run) and every run (Runs).
        status_colors = {"ok": "green", "partial": "orange", "skipped": "red"}
        for title in ("Last run", "Runs"):
            ov = [o for o in panels[title]["fieldConfig"].get("overrides", []) if o["matcher"] == {"id": "byName", "options": "status"}]
            maps = [x["value"] for x in ov[0]["properties"] if x["id"] == "mappings"] if ov else []
            got = {k: v.get("color") for m in (maps[0] if maps else []) for k, v in m.get("options", {}).items()}
            check(got == status_colors, f"{title}: status colours must be {status_colors}, got {got}")
        check(panels["Last run"]["targets"][0].get("direction", "backward") == "backward",
              "Last run: maxLines 1 must return the newest line (direction backward)")
        # In a Loki logs frame the | json fields exist only inside the labels field until extractFields runs.
        for title in ("Last run", "Runs", "Workloads"):
            tr = panels[title].get("transformations", [])
            got = [(x["id"], x["options"].get("source")) for x in tr]
            check(got[:2] == [("extractFields", "labels"), ("organize", None)],
                  f"{title}: transformations must start with extractFields (source labels), organize, got {got}")
        org = next((x["options"] for x in panels["Runs"].get("transformations", []) if x["id"] == "organize"), {})
        need = {"run_id", "status", "failed", "reason"}
        check(need <= set(org.get("indexByName", {})), f"Runs: columns {sorted(need)} must be placed (indexByName)")
        hidden = {k for k, v in org.get("excludeByName", {}).items() if v} & need
        check(not hidden, f"Runs: columns hidden: {sorted(hidden)}")
        check(panels["Runs"]["targets"][0].get("maxLines", 0) >= 100,
              "Runs: maxLines must be >= 100 (every run in the range, about 10 in 14 days, plus manual reruns)")
        # The Loki datasource's derived field adds an empty traceID column to logs-based tables.
        for title in ("Runs", "Workloads"):
            o = next((x["options"] for x in panels[title].get("transformations", []) if x["id"] == "organize"), {})
            check(o.get("excludeByName", {}).get("traceID") is True, f"{title}: the derived traceID column must be hidden")
        runs_fields = ["status", "reason", "posted", "failed", "dryRun", "auditCheck", "gator"]
        check(json_fields(panels["Runs"]["targets"][0]["expr"]) == runs_fields, f"Runs: | json must extract {runs_fields}")
for e in errors:
    print("  " + e, file=sys.stderr)
sys.exit(1 if errors else 0)
EOF

echo "OK"
