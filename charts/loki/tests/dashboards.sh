#!/usr/bin/env bash
# Tests the rendered Loki dashboard ConfigMap.
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
file=loki-overview.json
source_json="$src/files/dashboards/$file"
copy="$tmp/loki/files/dashboards/$file"
dashboard_json() {
  awk -v key="  $file: |-" '$0 == key { on = 1; next } on && /^  [^ ]/ { exit } on { print substr($0, 5) }'
}
namespace_scoped() {
  jq -e --arg filter 'namespace=~"$namespace"' '
    [.. | objects | .expr? // empty] | length > 0 and all(.[];
      [scan("[{][^}]*[}]")] | length > 0 and all(.[]; contains($filter)))' >/dev/null
}
[ "$(grep -c '^  [a-z0-9-]*\.json: |-$' <<<"$out")" = 1 ] || fail "expected only the Essential Metrics dashboard"
json=$(dashboard_json <<<"$out")
jq -e '.uid == "loki-3x-essentials" and .editable == false' <<<"$json" >/dev/null || fail "$file: expected provisioned dashboard UID and editable: false"
jq -e '[.. | objects | select(.type? == "prometheus") | .uid] | unique == ["prometheus"]' <<<"$json" >/dev/null || fail "$file: expected prometheus datasource"
namespace_scoped <<<"$json" || fail "$file: every selector must filter on the namespace variable"

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

# 5. Removing only the fallback selector's namespace filter must fail the scope check.
jq '(.panels[].targets[]? | select(.legendFormat == "Failures").expr) |=
  sub("loki_distributor_ingester_appends_total[{][^}]*[}]"; "loki_distributor_ingester_appends_total{}")' "$source_json" > "$copy"
out=$(render)
if dashboard_json <<<"$out" | namespace_scoped; then fail "unscoped Failures fallback passed"; fi

# 6. Both template guards report the affected file.
render_must_fail() {
  if render > /dev/null 2>"$tmp/err"; then fail "render succeeded with $1"; fi
  grep -Fq "$file: $1" "$tmp/err" || fail "missing render error: $1"
}
printf '{"title":' > "$copy"
render_must_fail "invalid JSON"
jq '.title = "__FOO__"' "$source_json" > "$copy"
render_must_fail "placeholder __FOO__ left after rendering"
cp "$source_json" "$copy"

echo "OK"
