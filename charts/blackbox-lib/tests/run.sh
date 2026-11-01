#!/usr/bin/env bash
# Usage: run.sh [--update]
# Renders each consumer chart with tests/cases/<consumer>/<case>.yaml and compares it with
# tests/expected/<consumer>/<case>.yaml (--update rewrites the expected files instead): the Service, or for
# alerts-*.yaml cases the alerts ConfigMap (templates/monitoring.yaml).
# Each tests/failures/<consumer>/<case>.yaml must fail with the error in its "# expect-error: <regex>" line.
set -euo pipefail

cd "$(dirname "$0")"
update=${1:-}
failed=0

render() {
  helm template t "consumers/$1" -n team-dev "${@:2}"
}

for values in cases/*/*.yaml; do
  consumer=$(basename "$(dirname "$values")")
  expected=expected/$consumer/$(basename "$values")
  template=templates/service.yaml
  [[ $(basename "$values") == alerts-* ]] && template=templates/monitoring.yaml
  actual=$(render "$consumer" -f "$values" --show-only "$template")
  if [[ $update == --update ]]; then
    mkdir -p "$(dirname "$expected")"
    echo "$actual" > "$expected"
    echo "updated $expected"
  elif diff -u "$expected" <(echo "$actual"); then
    echo "ok   $values"
  else
    echo "FAIL $values: output differs from $expected"
    failed=1
  fi
done

for values in failures/*/*.yaml; do
  consumer=$(basename "$(dirname "$values")")
  error=$(sed -n '1s/^# expect-error: //p' "$values")
  if output=$(render "$consumer" -f "$values" 2>&1 > /dev/null); then
    echo "FAIL $values: expected rendering to fail"
    failed=1
  elif grep -Eq -- "$error" <<< "$output"; then
    echo "ok   $values"
  else
    echo "FAIL $values: expected an error matching '$error', got:"
    echo "$output"
    failed=1
  fi
done

# Alerts render nothing unless blackbox.enabled and blackbox.alerts.enabled are both true. (With every rule off
# they still render, with only deleteRules: see cases/spec/alerts-all-off.yaml.)
for flags in "--set blackbox.enabled=true" "--set blackbox.alerts.enabled=true"; do
  # shellcheck disable=SC2086
  if ! output=$(render spec --set blackbox.alerts.team=raster $flags 2>&1); then
    echo "FAIL render failed with: $flags"
    echo "$output"
    failed=1
  elif grep -q 'mapcolonies.io/grafana-alerts' <<< "$output"; then
    echo "FAIL alerts rendered with: $flags"
    failed=1
  else
    echo "ok   no alerts with: $flags"
  fi
done

# helm --set passes decimals as strings (0.5 -> "0.5"); thresholds must accept them.
if threshold=$(render spec -f cases/spec/alerts-default.yaml --set blackbox.alerts.rules.latency.enabled=true \
    --set blackbox.alerts.rules.latency.maxSeconds=0.5 --show-only templates/monitoring.yaml 2>&1) &&
   grep -q -- '- 0.5$' <<< "$threshold"; then
  echo "ok   --set latency.maxSeconds=0.5 is accepted"
else
  echo "FAIL --set latency.maxSeconds=0.5:"
  echo "$threshold" | tail -3
  failed=1
fi

# The exporter name always holds release and chart name, also when the release name contains the chart name
# (no shortening: it made e.g. mapproxy and mapproxy-api in release raster-mapproxy-api collide).
exporter=$(helm template spec consumers/spec -n team-dev --set blackbox.enabled=true \
  --set blackbox.customExporter.enabled=true --set blackbox.module=m \
  --show-only templates/service.yaml | sed -n 's/.*prometheus.io\/probe-exporter: "\(.*\)"/\1/p')
if [[ $exporter == "spec-spec-blackbox.team-dev.svc:9115" ]]; then
  echo "ok   release named after the chart gives <release>-<chart>-blackbox"
else
  echo "FAIL release named after the chart: got probe-exporter '$exporter'"
  failed=1
fi

exit $failed
