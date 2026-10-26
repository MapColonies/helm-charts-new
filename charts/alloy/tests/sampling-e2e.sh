#!/usr/bin/env bash
# Runs the real Alloy binary against the rendered log pipeline (loki.process, OTel parsing,
# health filter and sampling), with the batcher swapped for loki.echo. Pushes N pod-style
# JSON lines per severity, with SeverityText in the body and no level label, and counts
# what survives.
# Usage: ALLOY=/path/to/alloy tests/sampling-e2e.sh [helm template args...]
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ALLOY:?set ALLOY to the alloy binary path}"
N=${N:-2000}
PUSH_PORT=${PUSH_PORT:-3599}
work=$(mktemp -d)
trap 'kill "${pid:-}" 2>/dev/null || true; rm -rf "$work"' EXIT

helm template alloy . "$@" | sed -n '/config.alloy: |-/,$p' | sed '1d; s/^    //' >"$work/rendered.alloy"

# Print one top-level block, from its header line to the closing brace at column 0
block() { awk -v hdr="$1 {" '!done && index($0, hdr) && $0 !~ /^ *\/\// {p=1} p{print} p && /^}/{p=0; done=1}' "$work/rendered.alloy"; }

{
  for b in 'loki.process "limit_time"' 'otelcol.receiver.loki "default"' 'otelcol.processor.transform "default"' \
    'otelcol.processor.filter "health_filter"' 'otelcol.processor.filter "log_sampling_drop"' \
    'otelcol.processor.transform "log_sampling_priority"' \
    'otelcol.processor.probabilistic_sampler "logs"' 'otelcol.processor.transform "log_sampling_cleanup"'; do
    block "$b"; echo
  done
} | sed 's|otelcol.processor.batch.default.input|otelcol.exporter.loki.out.input|' >"$work/pipeline.alloy"
grep -q 'otelcol.processor.filter "health_filter"' "$work/pipeline.alloy" || { echo "failed to extract the pipeline" >&2; exit 1; }

cat >"$work/config.alloy" <<CFG
loki.source.api "in" {
  http {
    listen_address = "127.0.0.1"
    listen_port    = $PUSH_PORT
  }
  forward_to = [loki.process.limit_time.receiver]
}

otelcol.exporter.loki "out" {
  forward_to = [loki.echo.out.receiver]
}

loki.echo "out" {}

$(cat "$work/pipeline.alloy")
CFG

echo "--- tested config"; cat "$work/config.alloy"; echo "---"

"$ALLOY" run "$work/config.alloy" --storage.path="$work/data" \
  --server.http.listen-addr=127.0.0.1:12399 --stability.level=experimental >"$work/alloy.log" 2>&1 &
pid=$!
for _ in $(seq 50); do curl -sf "http://127.0.0.1:12399/-/ready" >/dev/null && break; sleep 0.2; done
curl -sf "http://127.0.0.1:12399/-/ready" >/dev/null || { echo "alloy failed to start:" >&2; cat "$work/alloy.log" >&2; exit 1; }

# SeverityText is upper case, as OTel loggers write it; sampling keys are matched case-insensitively
levels=(trace debug info warn error)
for lvl in "${levels[@]}"; do
  now=$(date +%s%N)
  python3 - "$lvl" "$N" "$now" >"$work/push-$lvl.json" <<'PY'
import json, sys
lvl, n, now = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
line = lambda i: json.dumps({"Timestamp": str(now + i), "SeverityText": lvl.upper(),
  "Body": f"{lvl}-line-{i}", "Attributes": {}, "Resource": {}})
print(json.dumps({"streams": [{"stream": {"job": "e2e"},
  "values": [[str(now + i), line(i)] for i in range(n)]}]}))
PY
  curl -sf -H 'Content-Type: application/json' --data-binary @"$work/push-$lvl.json" \
    "http://127.0.0.1:$PUSH_PORT/loki/api/v1/push"
done
sleep 5

printf '\n%-6s %8s %8s %8s\n' level sent kept ratio
for lvl in "${levels[@]}"; do
  kept=$( (grep -o "$lvl-line-[0-9]*" "$work/alloy.log" || true) | sort -u | wc -l)
  printf '%-6s %8d %8d %8.3f\n' "$lvl" "$N" "$kept" "$(echo "$kept/$N" | bc -l)"
done
echo; echo "--- output lines with leftover sampling attributes (expect none)"
grep 'loki.echo' "$work/alloy.log" | grep 'sampling\.' | head -3 || echo "(none)"
echo; echo "--- example output line"
grep 'loki.echo' "$work/alloy.log" | grep -m1 'error-line-' || true
echo; echo "--- sampler metrics"
curl -s http://127.0.0.1:12399/metrics | grep -E '^otelcol_processor_probabilistic_sampler' || echo "(none)"
echo; echo "--- alloy errors"
grep -iE 'level=(error|warn)' "$work/alloy.log" | head -5 || echo "(none)"
