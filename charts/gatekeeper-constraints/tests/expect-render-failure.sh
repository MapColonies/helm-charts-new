#!/usr/bin/env bash
# Usage: expect-render-failure.sh <values-file>
#
# Renders the chart with <values-file> and fails unless rendering fails with an
# error matching the regex on the file's first line, "# expect-error: <regex>".
set -euo pipefail

values=$1
chart_dir=$(cd "$(dirname "$0")/.." && pwd)
expected=$(sed -n '1s/^# expect-error: //p' "$values")

if output=$(helm template gatekeeper-constraints "$chart_dir" -f "$values" 2>&1 > /dev/null); then
  echo "FAIL $values: expected rendering to fail"
  exit 1
fi
if ! grep -Eq -- "$expected" <<< "$output"; then
  echo "FAIL $values: expected an error matching '$expected', got:"
  echo "$output"
  exit 1
fi
echo "ok   $values"
