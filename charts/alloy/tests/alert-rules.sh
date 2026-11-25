#!/usr/bin/env bash
# Evaluates the rendered alert expressions (the alerts ConfigMap, as the chart ships them) with
# promtool, against synthetic series shaped like prod's scrape (tests/alert-rules.test.yaml): one
# job for both workloads, the Deployment's Alloy cluster unnamed and the StatefulSet's named
# alloy-logs. A Grafana rule here fires when its query
# (refId A) has returned a series for its `for`, so each becomes a Prometheus alerting rule on that
# query with the same `for`.
# Usage: PROMTOOL=/path/to/promtool tests/alert-rules.sh
source "$(dirname "$0")/lib.sh"
: "${PROMTOOL:?set PROMTOOL to the promtool binary path}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

alerts=$(render | yq 'select(.kind == "ConfigMap" and .metadata.name == "alloy-alerts") | .data')
{
  printf '%s\n' 'groups:' '  - name: alloy' '    rules:'
  for file in $(yq 'keys | .[]' <<<"$alerts"); do
    # Only refId A becomes the Prometheus rule, so every rule's condition must be C: last(A) > 0
    bad=$(F=$file yq '.[env(F)]' <<<"$alerts" | yq '.groups[].rules[] | select(.condition != "C" or ([.data[] | select(.refId == "C") | .model | select(.type == "classic_conditions" and (.conditions | length) == 1 and .conditions[0].evaluator.type == "gt" and (.conditions[0].evaluator.params | length) == 1 and .conditions[0].evaluator.params[0] == 0 and (.conditions[0].query.params | length) == 1 and .conditions[0].query.params[0] == "A" and .conditions[0].reducer.type == "last")] | length) != 1) | .title')
    [[ -z $bad ]] || fail "rules whose condition isn't last(A) > 0, which promtool can't check: $bad"
    F=$file yq '.[env(F)]' <<<"$alerts" \
      | yq -N '.groups[].rules[] | [{"alert": .title, "expr": (.data[] | select(.refId == "A") | .model.expr), "for": .for}]'
  done | sed 's/^/      /'
} >"$work/rules.yaml"
grep -q 'kube_statefulset_replicas' "$work/rules.yaml" || fail "no rendered alerts found"
"$PROMTOOL" check rules "$work/rules.yaml" >"$work/check.log" 2>&1 || { cat "$work/check.log" >&2; fail "alert expressions don't parse"; }
cp tests/alert-rules.test.yaml "$work/"
"$PROMTOOL" test rules "$work/alert-rules.test.yaml" || fail "alert rule tests"

echo "OK"
