#!/usr/bin/env bash
# Evaluates dashboard queries with promtool against synthetic series (tests/dashboard-queries.test.yaml):
# the append failures fallback (0 only while the distributor reports appends, no data without Loki
# telemetry) and the container restarts count (deduplicated across scrape jobs, Loki containers only).
# The queries are read from the dashboard file, with $namespace, $__rate_interval and $__range
# replaced by fixed values.
# Usage: PROMTOOL=/path/to/promtool tests/dashboard-queries.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PROMTOOL:?set PROMTOOL to the promtool binary path}"
fail() { echo "FAIL: $1" >&2; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
dashboard=files/dashboards/loki-overview.json

# expr <panel title> <legend>: the panel's query for that legend, with the Grafana variables filled in
expr() {
  jq -er --arg t "$1" --arg l "$2" '[.. | objects | select(.title? == $t) | .targets[] | select(.legendFormat == $l) | .expr] | if length == 1 then .[0] else error("expected one query") end' "$dashboard" \
    | sed -e 's/\$namespace/loki-ns/g' -e 's/\$__rate_interval/2m/g' -e 's/\$__range/10m/g'
}
failures=$(expr "Batch appends to ingesters / sec" "Failures") || fail "no Failures query"
restarts=$(expr "Restarts" "Restarts") || fail "no Container restarts query"

# Fill the test file's placeholders; the expressions go in as YAML single-quoted strings
quote() { printf "'%s'" "${1//\'/\'\'}"; }
F=$(quote "$failures") R=$(quote "$restarts") \
  awk '{ gsub(/__FAILURES__/, ENVIRON["F"]); gsub(/__RESTARTS__/, ENVIRON["R"]); print }' \
  tests/dashboard-queries.test.yaml > "$work/test.yaml"
"$PROMTOOL" test rules "$work/test.yaml" || fail "dashboard query tests"
echo "OK"
