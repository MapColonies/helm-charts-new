#!/usr/bin/env bash
# Evaluates the alert expressions in files/alerts with promtool, against synthetic series shaped like
# prod's scrape (tests/alert-rules.test.yaml): one job for both workloads, the Deployment's Alloy
# cluster unnamed and the StatefulSet's named alloy-logs. A Grafana rule here fires when its query
# (refId A) returns a series, so each becomes a Prometheus alerting rule on that query.
# Usage: PROMTOOL=/path/to/promtool tests/alert-rules.sh
source "$(dirname "$0")/lib.sh"
: "${PROMTOOL:?set PROMTOOL to the promtool binary path}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

{
  printf '%s\n' 'groups:' '  - name: alloy' '    rules:'
  for file in files/alerts/*.yaml; do
    yq -N '.groups[].rules[] | [{"alert": .title, "expr": (.data[] | select(.refId == "A") | .model.expr)}]' <"$file"
  done | sed 's/^/      /'
} >"$work/rules.yaml"
"$PROMTOOL" check rules "$work/rules.yaml" >"$work/check.log" 2>&1 || { cat "$work/check.log" >&2; fail "alert expressions don't parse"; }
cp tests/alert-rules.test.yaml "$work/"
"$PROMTOOL" test rules "$work/alert-rules.test.yaml" || fail "alert rule tests"

echo "OK"
