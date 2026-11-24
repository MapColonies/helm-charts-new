#!/usr/bin/env bash
# Usage: make-fixtures.sh GATOR OUT_DIR
# Writes the report.py test fixtures (see make_fixtures.py) to OUT_DIR. `make
# daily-report-fixtures` writes them to tests/daily-report/fixtures; parity.sh writes them to
# a temp dir and fails when the committed ones are stale.
set -euo pipefail
gator=$1
out=$2
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
helm template gatekeeper-constraints "$here/../.." \
  -s templates/constrainttemplate-workload-cpu-ratio.yaml \
  -s templates/constrainttemplate-workload-mclabels.yaml > "$tmp/templates.yaml"
"$here/yaml2json.sh" "$tmp/templates.yaml" > "$tmp/templates.jsonl"
rm -rf "$out/api"
python3 -I "$here/make_fixtures.py" "$tmp/templates.jsonl" "$gator" "$out" 2> "$tmp/log" || { cat "$tmp/log" >&2; exit 1; }
