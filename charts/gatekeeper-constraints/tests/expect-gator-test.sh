#!/usr/bin/env bash
# Usage: expect-gator-test.sh <case-dir>
# Renders the chart with <case-dir>/values.yaml, runs <case-dir>/objects through
# `gator test` and checks the outcome in <case-dir>/expect:
# nothing | warnings-only | denials.
set -euo pipefail

case_dir=${1%/}
chart_dir=$(cd "$(dirname "$0")/.." && pwd)
expect=$(< "$case_dir/expect")
render_dir=$(mktemp -d)
trap 'rm -rf "$render_dir"' EXIT

helm template gatekeeper-constraints "$chart_dir" -f "$case_dir/values.yaml" --output-dir "$render_dir" > /dev/null
files=(-f "$render_dir/gatekeeper-constraints/templates" -f "$case_dir/objects")

# gator test reads stdin without objects and exits non-zero on deny.
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
