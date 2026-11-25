#!/usr/bin/env bash
# Asserts on the rendered dashboards ConfigMap: its folder (default: the alert rules' folder
# <alerts.team>/<alerts.component>, dashboards.folder wins), namespace, enabled switch, and that
# every dashboard is the upstream file with only its two datasource variables pinned, hidden and
# excluded from the URL.
set -euo pipefail
cd "$(dirname "$0")/.."

render() { helm template infra-alloy . --namespace infra-x --show-only templates/dashboards.yaml "$@"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
folder() { sed -n 's/^    mapcolonies.io\/grafana-dashboards-folder: "\(.*\)"$/\1/p' <<<"$1"; }
namespace() { sed -n 's/^  namespace: \(.*\)$/\1/p' <<<"$1"; }
# Print one rendered dashboard's JSON: the block scalar under "  <file>: |-", without its 4-space indent.
dashboard() {
  awk -v key="  $2: |-" '$0 == key { on = 1; next } on && /^  [^ ]/ { exit } on { print substr($0, 5) }' <<<"$1"
}
# The upstream file with only the two datasource variables pinned to $2 / $3, hidden and not URL-synced.
expected() {
  jq --arg prom "$2" --arg loki "$3" '
    .templating.list |= map(
      if .type == "datasource" and .name == "datasource" then .current = {selected: true, text: $prom, value: $prom} | .hide = 2 | .skipUrlSync = true
      elif .type == "datasource" and .name == "loki_datasource" then .current = {selected: true, text: $loki, value: $loki} | .hide = 2 | .skipUrlSync = true
      else . end)' "$1"
}
# Canonical JSON for comparing: sorted keys, and every number re-encoded as a float. Helm writes
# numbers as Go floats (0.10000000000000001 -> 0.1), and jq 1.7+ keeps an unmodified number as written.
canon() { jq -S 'walk(if type == "number" then . + 0 else . end)'; }
files=$(ls files/dashboards/*.json | wc -l | tr -d ' ')

# 1. defaults: release namespace, the alert rules' folder, every file pinned to prometheus/loki and otherwise unchanged
out=$(render)
[ "$(folder "$out")" = "infra/Alloy" ] || fail "default folder must be infra/Alloy, got $(folder "$out")"
[ "$(namespace "$out")" = "infra-x" ] || fail "default namespace must be the release namespace"
[ "$(grep -c '^  [a-z0-9-]*\.json: |-$' <<<"$out")" = "$files" ] || fail "all $files dashboards must be rendered"
for f in files/dashboards/*.json; do
  got=$(dashboard "$out" "$(basename "$f")" | canon) || fail "$(basename "$f") must render as valid JSON"
  [ "$got" = "$(expected "$f" prometheus loki | canon)" ] \
    || fail "$(basename "$f") must equal the source with only datasource/loki_datasource pinned, hidden and not URL-synced"
done

# 2. a missing dashboards map uses the defaults
out=$(render --set dashboards=null)
[ "$(folder "$out")" = "infra/Alloy" ] || fail "dashboards=null must use the alert rules' folder"
[ "$(dashboard "$out" alloy-logs.json | jq -r '.templating.list[] | select(.name=="datasource") | .current.value')" = "prometheus" ] \
  || fail "dashboards=null must pin the default Prometheus uid"

# 3. the folder follows the alert rules' folder, and dashboards.folder wins over it
out=$(render --set alerts.team=raster --set alerts.component=Collector)
[ "$(folder "$out")" = "raster/Collector" ] || fail "folder must follow alerts.team/alerts.component"
out=$(render --set alerts.team=raster --set alerts.component=Collector --set dashboards.folder=Monitoring/Alloy)
[ "$(folder "$out")" = "Monitoring/Alloy" ] || fail "dashboards.folder must win over the alert rules' folder"

# 4. namespace and enabled, each on its own
out=$(render --set dashboards.namespace=monitoring)
[ "$(namespace "$out")" = "monitoring" ] || fail "dashboards.namespace must set the ConfigMap namespace"
[ "$(folder "$out")" = "infra/Alloy" ] || fail "dashboards.namespace must not change the folder"
# enabled=false: the whole chart must still render, just without the dashboards ConfigMap
all=$(helm template infra-alloy . --namespace infra-x --set dashboards.enabled=false) \
  || fail "the chart must render with dashboards.enabled=false"
grep -q '^  name: infra-alloy-alerts$' <<<"$all" || fail "dashboards.enabled=false must keep the other objects"
grep -q '^  name: infra-alloy-dashboards$' <<<"$all" && fail "dashboards.enabled=false must render no dashboards ConfigMap"

# 5. non-default datasource uids are pinned in every dashboard
out=$(render --set dashboards.prometheusDatasourceUid=prom-x --set dashboards.lokiDatasourceUid=loki-x)
for f in files/dashboards/*.json; do
  [ "$(dashboard "$out" "$(basename "$f")" | canon)" = "$(expected "$f" prom-x loki-x | canon)" ] \
    || fail "$(basename "$f") must pin prom-x/loki-x"
done

# 6. invalid values and an invalid dashboard fail the render
for args in "--set dashboards.prometheusDatasourceUid=" "--set dashboards.lokiDatasourceUid="; do
  # shellcheck disable=SC2086
  if render $args >/dev/null 2>&1; then fail "render must fail with $args"; fi
done
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp -r . "$tmp/alloy"
printf '{ "title": ' > "$tmp/alloy/files/dashboards/alloy-logs.json"
if helm template infra-alloy "$tmp/alloy" --show-only templates/dashboards.yaml >/dev/null 2>"$tmp/err"; then
  fail "an invalid dashboard JSON must fail the render"
fi
grep -q 'alloy-logs.json: invalid JSON' "$tmp/err" || fail "the error must name the invalid file"
cp files/dashboards/alloy-logs.json "$tmp/alloy/files/dashboards/alloy-logs.json"

# 7. each dashboard must have exactly one datasource and one loki_datasource variable
#    (a dashboard with two "datasource" and no "loki_datasource" must fail, not count as 2)
jq '(.templating.list[] | select(.name == "loki_datasource")).name = "datasource"' files/dashboards/alloy-controller.json \
  > "$tmp/alloy/files/dashboards/alloy-controller.json"
if helm template infra-alloy "$tmp/alloy" --show-only templates/dashboards.yaml >/dev/null 2>"$tmp/err"; then
  fail "a dashboard with two datasource variables and no loki_datasource must fail the render"
fi
grep -q 'alloy-controller.json: expected exactly one datasource variable' "$tmp/err" || fail "the error must name the dashboard: $(cat "$tmp/err")"
jq 'del(.templating.list[] | select(.name == "loki_datasource"))' files/dashboards/alloy-controller.json \
  > "$tmp/alloy/files/dashboards/alloy-controller.json"
if helm template infra-alloy "$tmp/alloy" --show-only templates/dashboards.yaml >/dev/null 2>&1; then
  fail "a dashboard without loki_datasource must fail the render"
fi

echo "OK"
