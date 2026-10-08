#!/usr/bin/env bash
# Lint and render a chart against its ci/ values files.
#   ci/*-values.yaml          must lint and render
#   ci/invalid/*-values.yaml  must fail to render with the message in its
#                             "# expect-error: <substring>" line
# Charts without a ci/ directory are skipped.
set -euo pipefail

chart_dir="${1:?usage: render-chart.sh <chart-dir>}"
chart_dir="${chart_dir%/}"

if [[ ! -d "$chart_dir/ci" ]]; then
  echo "No ci/ directory in $chart_dir, skipping"
  exit 0
fi

name=$(yq -r '.name' "$chart_dir/Chart.yaml")
domain=$(yq -r '.annotations.domain // ""' "$chart_dir/Chart.yaml")
# Match the helmfile release name (<domain>-<chart>); some upstream resource names only change under it.
release="${domain:+$domain-}$name"

if yq -e '.dependencies | length > 0' "$chart_dir/Chart.yaml" >/dev/null 2>&1; then
  helm dependency update "$chart_dir"
fi

failed=0
shopt -s nullglob

valid=("$chart_dir"/ci/*-values.yaml)
if (( ${#valid[@]} == 0 )); then
  echo "::error::$chart_dir/ci has no *-values.yaml files"
  exit 1
fi

for values in "${valid[@]}"; do
  echo "::group::$values"
  if helm lint "$chart_dir" -f "$values" && helm template "$release" "$chart_dir" -f "$values" >/dev/null; then
    echo "OK: $values"
  else
    echo "::error file=$values::lint/render failed"
    failed=1
  fi
  echo "::endgroup::"
done

for values in "$chart_dir"/ci/invalid/*-values.yaml; do
  expected=$(sed -n 's/^# expect-error: //p' "$values" | head -n1)
  if [[ -z "$expected" ]]; then
    echo "::error file=$values::missing '# expect-error: <substring>' line"
    failed=1
    continue
  fi
  if err=$(helm template "$release" "$chart_dir" -f "$values" 2>&1 >/dev/null); then
    echo "::error file=$values::rendered successfully, expected failure: $expected"
    failed=1
  elif [[ "$err" != *"$expected"* ]]; then
    echo "::error file=$values::failed with a different error; expected: $expected; got: $err"
    failed=1
  else
    echo "OK (failed as expected): $values"
  fi
done

exit "$failed"
