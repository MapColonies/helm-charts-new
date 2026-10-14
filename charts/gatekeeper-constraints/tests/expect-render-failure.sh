#!/usr/bin/env bash
# Usage: expect-render-failure.sh <values-file>
# Passes if rendering fails with the error in the file's "# expect-error: <regex>" line.
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
