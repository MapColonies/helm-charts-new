#!/usr/bin/env bash
# Render test for templates/dashboards.yaml (loki): defaults, a missing dashboards map, enabled=false,
# and the datasource uid. Renders a copy of the chart without its dependencies (the template
# doesn't use them), so no registry access is needed.
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/loki"
cp -r "$src/templates" "$src/files" "$src/values.yaml" "$tmp/loki/"
printf 'apiVersion: v2\nname: loki\nversion: 0.0.0\n' > "$tmp/loki/Chart.yaml"
render() { helm template infra-loki "$tmp/loki" --namespace infra-x "$@"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
folder() { sed -n 's/^    mapcolonies.io\/grafana-dashboards-folder: "\(.*\)"$/\1/p' <<<"$1"; }
dashboards_cm() { grep -c '^  name: infra-loki-dashboards$' <<<"$1" || true; }

# 1. defaults: one ConfigMap with the sidecar label and folder, valid JSON, datasource pinned, no placeholder left
out=$(render)
[ "$(dashboards_cm "$out")" = 1 ] || fail "defaults must render the dashboards ConfigMap"
grep -q '^    mapcolonies.io/grafana-dashboards: "true"$' <<<"$out" || fail "the sidecar label is missing"
[ "$(folder "$out")" = "infra/Loki" ] || fail "default folder must be infra/Loki"
grep -q '^  namespace: infra-x$' <<<"$out" || fail "default namespace must be the release namespace"
# every dashboard file: its own key in the ConfigMap, valid JSON with its uid, editable: false,
# every Prometheus datasource pinned, and (dev Prometheus also scrapes the prod Loki) every query
# filtered on the namespace variable
declare -A uids=([loki-overview.json]=loki-3x-essentials [loki-global-metrics.json]=MQHVDmtWk)
[ "$(ls "$src"/files/dashboards/*.json | wc -l)" = "${#uids[@]}" ] || fail "a dashboard file has no expected uid in this test"
[ "$(grep -c '^  [a-z0-9-]*\.json: |-$' <<<"$out")" = "${#uids[@]}" ] || fail "every dashboard file must be rendered"
for file in "${!uids[@]}"; do
  json=$(awk -v key="  $file: |-" '$0 == key { on = 1; next } on && /^  [^ ]/ { exit } on { print substr($0, 5) }' <<<"$out")
  jq -e --arg uid "${uids[$file]}" '.uid == $uid' <<<"$json" >/dev/null || fail "$file must render as valid JSON with uid ${uids[$file]}"
  jq -e '.editable == false' <<<"$json" >/dev/null || fail "$file must be editable: false, like the other infra dashboards"
  [ "$(jq '[.. | objects | select(.type? == "prometheus" and has("uid")) | .uid] | unique' -c <<<"$json")" = '["prometheus"]' ] \
    || fail "$file: every Prometheus datasource must be pinned to prometheus"
  [ "$(jq '[.. | objects | select(has("expr")) | select(.expr | contains("namespace=~\"$namespace\"") | not)] | length' <<<"$json")" = 0 ] \
    || fail "$file: every query must filter on namespace=~\"\$namespace\""
done

# 2. a missing dashboards map uses the defaults (no nil pointer)
out=$(render --set dashboards=null) || fail "dashboards=null must render"
[ "$(dashboards_cm "$out")" = 1 ] && [ "$(folder "$out")" = "infra/Loki" ] || fail "dashboards=null must use the defaults"

# 3. an explicit enabled=false renders no ConfigMap
out=$(render --set dashboards.enabled=false)
[ "$(dashboards_cm "$out")" = 0 ] || fail "dashboards.enabled=false must render no dashboards ConfigMap"

# 4. folder, namespace and datasource uid are configurable; an empty uid fails
out=$(render --set dashboards.folder=Monitoring/Loki --set dashboards.namespace=monitoring --set dashboards.prometheusDatasourceUid=prom-x)
[ "$(folder "$out")" = "Monitoring/Loki" ] || fail "dashboards.folder must set the folder"
grep -q '^  namespace: monitoring$' <<<"$out" || fail "dashboards.namespace must set the namespace"
grep -q '"uid": "prom-x"' <<<"$out" || fail "dashboards.prometheusDatasourceUid must be pinned"
if render --set dashboards.prometheusDatasourceUid= >/dev/null 2>&1; then fail "an empty dashboards.prometheusDatasourceUid must fail"; fi

echo "OK"
