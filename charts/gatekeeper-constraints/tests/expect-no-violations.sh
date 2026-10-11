#!/usr/bin/env bash
# Usage: expect-no-violations.sh <case-dir>
#
# Renders the chart with <case-dir>/values.yaml (and nothing else) and runs every
# object in <case-dir>/objects against all rendered ConstraintTemplates and
# Constraints with `gator test`. Fails if any object gets a violation of any
# enforcement action. Covers what a gator Suite can't: that a Constraint is not
# rendered at all.
set -euo pipefail

case_dir=${1%/}
chart_dir=$(cd "$(dirname "$0")/.." && pwd)
render_dir=$(mktemp -d)
trap 'rm -rf "$render_dir"' EXIT

helm template gatekeeper-constraints "$chart_dir" -f "$case_dir/values.yaml" --output-dir "$render_dir" > /dev/null

if ! output=$("${GATOR:-gator}" test -f "$render_dir/gatekeeper-constraints/templates" -f "$case_dir/objects" 2>&1 < /dev/null) || [[ -n $output ]]; then
  echo "FAIL $case_dir: expected no violations, got:"
  echo "$output"
  exit 1
fi
echo "ok   $case_dir"
