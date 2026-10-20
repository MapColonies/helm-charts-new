#!/usr/bin/env bash
# Usage: run.sh [--update]
# Renders each consumer chart's Service with tests/cases/<consumer>/<case>.yaml and compares it with
# tests/expected/<consumer>/<case>.yaml (--update rewrites the expected files instead).
# Each tests/failures/<consumer>/<case>.yaml must fail with the error in its "# expect-error: <regex>" line.
set -euo pipefail

cd "$(dirname "$0")"
update=${1:-}
failed=0

render() {
  helm template t "consumers/$1" -n team-dev "${@:2}" --show-only templates/service.yaml
}

annotations() {
  sed -n '/^  annotations:/,/^spec:/p'
}

for values in cases/*/*.yaml; do
  consumer=$(basename "$(dirname "$values")")
  expected=expected/$consumer/$(basename "$values")
  actual=$(render "$consumer" -f "$values")
  if [[ $update == --update ]]; then
    mkdir -p "$(dirname "$expected")"
    echo "$actual" > "$expected"
    echo "updated $expected"
  elif diff -u "$expected" <(echo "$actual"); then
    echo "ok   $values"
  else
    echo "FAIL $values: output differs from $expected"
    failed=1
  fi
done

for values in failures/*/*.yaml; do
  consumer=$(basename "$(dirname "$values")")
  error=$(sed -n '1s/^# expect-error: //p' "$values")
  if output=$(render "$consumer" -f "$values" 2>&1 > /dev/null); then
    echo "FAIL $values: expected rendering to fail"
    failed=1
  elif grep -Eq -- "$error" <<< "$output"; then
    echo "ok   $values"
  else
    echo "FAIL $values: expected an error matching '$error', got:"
    echo "$output"
    failed=1
  fi
done

# Both calling forms must produce the same annotations for the same Service name and port.
spec=$(render spec --set blackbox.enabled=true --set service.name=same-svc --set service.port=8080 | annotations)
explicit=$(render boilerplate --set blackbox.enabled=true --set fullnameOverride=same-svc --set server.port=8080 | annotations)
if [[ $spec == "$explicit" ]]; then
  echo "ok   both calling forms give the same annotations"
else
  echo "FAIL calling forms differ:"
  diff <(echo "$spec") <(echo "$explicit") || true
  failed=1
fi

exit $failed
