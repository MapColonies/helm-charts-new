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
json=$(awk '/^  loki-overview.json: \|-$/ { on = 1; next } on { print substr($0, 5) }' <<<"$out")
jq -e '.uid == "loki-3x-essentials"' <<<"$json" >/dev/null || fail "the dashboard must render as valid JSON with its uid"
jq -e '.editable == false' <<<"$json" >/dev/null || fail "the dashboard must be editable: false, like the other infra dashboards"
[ "$(jq '[.. | objects | select(.type? == "prometheus" and has("uid")) | .uid] | unique' -c <<<"$json")" = '["prometheus"]' ] \
  || fail "every Prometheus datasource must be pinned to prometheus"
# dev Prometheus also scrapes the prod Loki, so every query must filter on the namespace variable
[ "$(jq '[.. | objects | select(has("expr")) | select(.expr | contains("namespace=~\"$namespace\"") | not)] | length' <<<"$json")" = 0 ] \
  || fail "every query must filter on namespace=~\"\$namespace\""

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
