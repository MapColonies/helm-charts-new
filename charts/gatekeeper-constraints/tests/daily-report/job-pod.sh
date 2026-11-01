#!/usr/bin/env bash
# Usage: GATOR=<gator> job-pod.sh
# The daily-report job's own Pod passes every policy of this chart: the Pod label,
# annotation and label-value rules (chart defaults, a superset of dev), and the workload
# rules (1:4 CPU, mclabels) for its Pod template in a warn namespace.
set -euo pipefail
cd "$(dirname "$0")/../.."
gator=${GATOR:-gator}
fail() { echo "FAIL: $1" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

helm template gatekeeper-constraints . -n gatekeeper-system -f tests/values.yaml \
  --set dailyReport.enabled=true --set dailyReport.namespace=infra-dev --set dailyReport.environment=dev \
  --set dailyReport.dashboardUrl=https://grafana.invalid/d/x \
  --set dailyReport.loki.pushUrl=http://loki.invalid/loki/api/v1/push \
  --output-dir "$tmp/rendered" > /dev/null
templates=$tmp/rendered/gatekeeper-constraints/templates
tests/daily-report/yaml2json.sh "$templates/daily-report.yaml" | python3 -I tests/daily-report/helpers.py job-pod "$tmp/objects"
mkdir "$tmp/policies"
cp "$templates"/constraint*.yaml "$tmp/policies/"
[ "$(ls "$tmp/policies" | wc -l)" -ge 10 ] || fail "expected the Pod and workload Constraints to render"
out=$("$gator" test -f "$tmp/policies" -f "$tmp/objects" < /dev/null 2>&1) || true
[ -z "$out" ] || fail "the daily-report Pod breaks a policy: $out"
echo "ok   daily-report job Pod passes every policy"
