#!/usr/bin/env bash
# Asserts on the rendered alert rules ConfigMap: alerts.team sets every rule's alert_team label
# and, with alerts.component, the folder <team>/<component>. Grafana's own {{ }} templates in the
# rule files must survive the render, and bad values must fail it.
set -euo pipefail
cd "$(dirname "$0")/.."

render() { helm template infra-alloy . --show-only templates/alerts.yaml "$@"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
files=$(ls files/alerts/*.yaml | wc -l | tr -d ' ')
rules=$(grep -c '__ALERT_TEAM__' files/alerts/*.yaml | awk -F: '{n+=$2} END{print n}')

# 1. defaults: every file in infra/Alloy, every rule alert_team "infra", no placeholder left
out=$(render)
[ "$(grep -c '^        folder: "infra/Alloy"$' <<<"$out")" = "$files" ] || fail "each of the $files files must be in folder infra/Alloy"
[ "$(grep -c '^              alert_team: "infra"$' <<<"$out")" = "$rules" ] || fail "each of the $rules rules must have alert_team \"infra\""
grep -q '__ALERT_TEAM__\|__FOLDER__' <<<"$out" && fail "a placeholder was not replaced"

# 2. Grafana templates are passed through, not rendered by Helm
[ "$(grep -c '{{ *\$labels' <<<"$out")" = "$(cat files/alerts/*.yaml | grep -c '{{ *\$labels')" ] \
  || fail "Grafana {{ \$labels }} templates must be kept as written"

# 3. overrides
out=$(render --set alerts.team=raster --set alerts.component=Collector)
grep -q '^        folder: "raster/Collector"$' <<<"$out" || fail "folder must follow alerts.team and alerts.component"
grep -q 'alert_team: "infra"' <<<"$out" && fail "alert_team must follow alerts.team"
render --set 'alerts.component=OpenTelemetry Collector' | grep -q '^        folder: "infra/OpenTelemetry Collector"$' \
  || fail "a component with a space must be allowed"

# 4. a team starting with a digit stays a string
render --set alerts.team=3d | grep -q '^              alert_team: "3d"$' || fail "alert_team 3d must be quoted"

# 5. invalid values fail the render
for args in "--set alerts.team=Infra" "--set alerts.team=" "--set alerts.component=" "--set alerts.component=a/b"; do
  # shellcheck disable=SC2086
  if render $args >/dev/null 2>&1; then fail "render must fail with $args"; fi
done
# the component is written inside a quoted YAML string, so a quote or other symbol must fail the render
for component in 'My "Alloy"' 'a:b' ' Alloy'; do
  if render --set "alerts.component=$component" >/dev/null 2>&1; then fail "render must fail with alerts.component=$component"; fi
done

echo "OK"
