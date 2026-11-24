#!/usr/bin/env bash
# Usage: GATOR=<gator> parity.sh
# 1. Projection parity: gator on the chart's workload Constraints and tests/objects gives the
#    same results as gator on what report.py writes from the same objects served as raw API
#    JSON (no kind/apiVersion on list items). So the projection keeps every field the Rego
#    reads (init containers, annotations, Pod template labels, ...) and adds no result.
# 2. The committed report.py fixtures are what make-fixtures.sh writes today.
set -euo pipefail
cd "$(dirname "$0")/../.."
gator=${GATOR:-gator}
here=tests/daily-report
fail() { echo "FAIL: $1" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. projection parity
helm template gatekeeper-constraints . -f tests/values.yaml \
  -s templates/constrainttemplate-workload-cpu-ratio.yaml -s templates/constrainttemplate-workload-mclabels.yaml \
  -s templates/constraint-workload-cpu-ratio-warn.yaml -s templates/constraint-workload-cpu-ratio-enforced.yaml \
  -s templates/constraint-workload-mclabels-warn.yaml -s templates/constraint-workload-mclabels-enforced.yaml \
  > "$tmp/policies.yaml"
mapfile -t objects < <(find tests/objects/cpu-ratio tests/objects/mclabels tests/objects/exemptions -name '*.yaml' | sort)
"$here/yaml2json.sh" "$tmp/policies.yaml" "${objects[@]}" | python3 -I "$here/helpers.py" api "$tmp/api"
printf '{"entries":[],"defaultTeam":"infra","teams":["infra"],"webhookEnv":{"infra":"INFRA_WEBHOOK"}}' > "$tmp/teams.json"
# a dry run still fails a team without a webhook; this one is never posted to
env -i PATH="$PATH" INFRA_WEBHOOK=https://hooks.invalid/dry-run python3 -I files/daily-report/report.py --from-files "$tmp/api" --dry-run \
  --teams "$tmp/teams.json" --gator "$gator" --work "$tmp/work" > /dev/null 2> "$tmp/report.log" \
  || { cat "$tmp/report.log" >&2; fail "report.py --from-files failed"; }
args=(-f "$tmp/policies.yaml")
for o in "${objects[@]}"; do args+=(-f "$o"); done
"$gator" test "${args[@]}" -o json < /dev/null 2> /dev/null \
  | python3 -I "$here/helpers.py" results | sort > "$tmp/original" || true
"$gator" test -f "$tmp/work/in" -o json < /dev/null | python3 -I "$here/helpers.py" results | sort > "$tmp/projected"
[ "$(wc -l < "$tmp/original")" -ge 20 ] || fail "gator found too few results on tests/objects ($(wc -l < "$tmp/original"))"
diff "$tmp/original" "$tmp/projected" > "$tmp/parity.diff" \
  || { cat "$tmp/parity.diff" >&2; fail "gator results differ between the original objects (<) and report.py's projection (>)"; }

# 2. fixtures are current
"$here/make-fixtures.sh" "$gator" "$tmp/fixtures"
diff -r "$here/fixtures" "$tmp/fixtures" > "$tmp/fixtures.diff" \
  || { cat "$tmp/fixtures.diff" >&2; fail "tests/daily-report/fixtures are stale: run make daily-report-fixtures"; }
echo "ok   daily-report parity ($(wc -l < "$tmp/original") results)"
