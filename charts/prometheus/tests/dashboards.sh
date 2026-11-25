#!/usr/bin/env bash
# Render test for templates/dashboards.yaml: defaults, a missing dashboards map, enabled=false,
# and the datasource uid. Renders a copy of the chart without its dependencies (the template
# doesn't use them), so no registry access is needed.
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/prometheus"
cp -r "$src/templates" "$src/files" "$src/values.yaml" "$tmp/prometheus/"
printf 'apiVersion: v2\nname: prometheus\nversion: 0.0.0\n' > "$tmp/prometheus/Chart.yaml"
render() { helm template infra-prometheus "$tmp/prometheus" --namespace infra-x "$@"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
folder() { sed -n 's/^    mapcolonies.io\/grafana-dashboards-folder: "\(.*\)"$/\1/p' <<<"$1"; }
dashboards_cm() { grep -c '^  name: infra-prometheus-dashboards$' <<<"$1" || true; }

# 1. defaults: one ConfigMap with the sidecar label and folder, valid JSON, datasource pinned, no placeholder left
out=$(render)
[ "$(dashboards_cm "$out")" = 1 ] || fail "defaults must render the dashboards ConfigMap"
grep -q '^    mapcolonies.io/grafana-dashboards: "true"$' <<<"$out" || fail "the sidecar label is missing"
[ "$(folder "$out")" = "infra/Prometheus" ] || fail "default folder must be infra/Prometheus"
grep -q '^  namespace: infra-x$' <<<"$out" || fail "default namespace must be the release namespace"
json=$(awk '/^  prometheus-overview.json: \|-$/ { on = 1; next } on { print substr($0, 5) }' <<<"$out")
jq -e '.uid == "k8s_addons_prometheus"' <<<"$json" >/dev/null || fail "the dashboard must render as valid JSON with its uid"
jq -e '.editable == false' <<<"$json" >/dev/null || fail "the dashboard must be editable: false, like the other infra dashboards"
[ "$(jq '[.. | objects | select(.type? == "prometheus" and has("uid")) | .uid] | unique' -c <<<"$json")" = '["prometheus"]' ] \
  || fail "every Prometheus datasource must be pinned to prometheus"

# 2. a missing dashboards map uses the defaults (no nil pointer)
out=$(render --set dashboards=null) || fail "dashboards=null must render"
[ "$(dashboards_cm "$out")" = 1 ] && [ "$(folder "$out")" = "infra/Prometheus" ] || fail "dashboards=null must use the defaults"

# 3. an explicit enabled=false renders no ConfigMap
out=$(render --set dashboards.enabled=false)
[ "$(dashboards_cm "$out")" = 0 ] || fail "dashboards.enabled=false must render no dashboards ConfigMap"

# 4. folder, namespace and datasource uid are configurable; an empty uid fails
out=$(render --set dashboards.folder=Monitoring/Prometheus --set dashboards.namespace=monitoring --set dashboards.datasourceUid=prom-x)
[ "$(folder "$out")" = "Monitoring/Prometheus" ] || fail "dashboards.folder must set the folder"
grep -q '^  namespace: monitoring$' <<<"$out" || fail "dashboards.namespace must set the namespace"
grep -q '"uid": "prom-x"' <<<"$out" || fail "dashboards.datasourceUid must be pinned"
if render --set dashboards.datasourceUid= >/dev/null 2>&1; then fail "an empty dashboards.datasourceUid must fail"; fi

echo "OK"
