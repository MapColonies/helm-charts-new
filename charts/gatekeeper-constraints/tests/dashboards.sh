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
        exprs = [(p["title"], t["expr"]) for p in dash["panels"] for t in p.get("targets", [])]
        check(len(exprs) > 0, "no queries")
        for title, expr in exprs:
            if "gatekeeper-system" in expr:   # admission lines, not report lines
                check("count by (resource_namespace, resource_kind, resource_name, constraint_name)" in expr,
                      f"{title}: admission lines must be counted per distinct workload")
                continue
            check(sel in expr, f"{title}: query must read {sel}}}: {expr}")
            check("sum_over_time" not in expr, f"{title}: never sum lines over time (reruns would add up)")
            if "unwrap" in expr:
                check('| __error__=""' in expr, f"{title}: unwrap must drop parse errors")
            if "$run" not in expr and "_run" not in expr:
                check('type="team_total"' in expr and "max by (team)" in expr,
                      f"{title}: a query across runs must take max of the per-team total lines")
            if 'type="summary"' in expr or 'type="violation"' in expr:
                check('run_id="$run"' in expr and 'namespace=~"$namespace"' in expr and 'team=~"$team"' in expr,
                      f"{title}: per-namespace lines must be filtered by run, team and namespace")
        rules = set(re.findall(r'rule="(\w+)"', " ".join(e for _, e in exprs)))
        check(rules == {"cpuRatio", "mclabels"}, f"rules queried: {rules}")
        fields = set(re.findall(r"unwrap (\w+)", " ".join(e for _, e in exprs)))
        check(fields == {"workloads", "containers", "missing", "invalid"}, f"unwrapped fields: {fields}")
        check(any('team="_run"' in e for _, e in exprs), "a panel must show the run lines (status)")
for e in errors:
    print("  " + e, file=sys.stderr)
sys.exit(1 if errors else 0)
EOF

echo "OK"
