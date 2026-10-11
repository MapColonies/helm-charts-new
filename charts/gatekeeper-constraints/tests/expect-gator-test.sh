#!/usr/bin/env bash
# Usage: expect-gator-test.sh <case-dir>
#
# Renders the chart with <case-dir>/values.yaml (and nothing else) and runs every
# object in <case-dir>/objects against all rendered ConstraintTemplates and
# Constraints with `gator test`. <case-dir>/expect names the outcome:
#   nothing        no violation of any enforcement action, e.g. because an empty
#                  namespace list renders no Constraint
#   warnings-only  violations, none of them deny
#   denials        at least one deny violation
# This covers what a gator Suite can't: which Constraints the chart renders at
# all, and with which enforcement action.
set -euo pipefail

case_dir=${1%/}
chart_dir=$(cd "$(dirname "$0")/.." && pwd)
expect=$(< "$case_dir/expect")
render_dir=$(mktemp -d)
trap 'rm -rf "$render_dir"' EXIT

helm template gatekeeper-constraints "$chart_dir" -f "$case_dir/values.yaml" --output-dir "$render_dir" > /dev/null
files=(-f "$render_dir/gatekeeper-constraints/templates" -f "$case_dir/objects")

# gator test reads stdin when given no objects, and exits non-zero on deny violations.
all=$("${GATOR:-gator}" test "${files[@]}" 2>&1 < /dev/null || true)
denied=$("${GATOR:-gator}" test --deny-only "${files[@]}" 2>&1 < /dev/null || true)

case $expect in
  nothing) [[ -z $all ]] ;;
  warnings-only) [[ -n $all && -z $denied ]] ;;
  denials) [[ -n $denied ]] ;;
  *) echo "FAIL $case_dir: unknown expect '$expect'"; exit 1 ;;
esac || {
  echo "FAIL $case_dir: expected $expect, got:"
  echo "${all:-<no violations>}"
  exit 1
}
echo "ok   $case_dir ($expect)"
