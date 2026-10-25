#!/usr/bin/env bash
# Runs the real Alloy binary against the rendered loki.process "limit_time" block:
# pushes N lines per level (with a `level` label) through it and counts what survives.
# Usage: ALLOY=/path/to/alloy tests/sampling-e2e.sh [helm template args...]
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ALLOY:?set ALLOY to the alloy binary path}"
N=${N:-2000}
PUSH_PORT=${PUSH_PORT:-3599}
work=$(mktemp -d)
trap 'kill "${pid:-}" 2>/dev/null || true; rm -rf "$work"' EXIT

# Extract the rendered loki.process block and rewire it to loki.echo
helm template alloy . "$@" | sed -n '/config.alloy: |-/,$p' | sed '1d; s/^    //' \
  | awk '!done && /^ *loki.process "limit_time"/{p=1} p{print} p && /^}/{p=0; done=1}' \
  | sed 's|forward_to = \[otelcol.receiver.loki.default.receiver\]|forward_to = [loki.echo.out.receiver]|' \
  > "$work/process.alloy"
grep -q 'loki.echo.out' "$work/process.alloy" || { echo "failed to extract loki.process block" >&2; exit 1; }

cat > "$work/config.alloy" <<CFG
loki.source.api "in" {
  http {
    listen_address = "127.0.0.1"
    listen_port    = $PUSH_PORT
  }
  forward_to = [loki.process.limit_time.receiver]
}

loki.echo "out" {}

$(cat "$work/process.alloy")
CFG

echo "--- tested config"; cat "$work/config.alloy"; echo "---"

"$ALLOY" run "$work/config.alloy" --storage.path="$work/data" \
  --server.http.listen-addr=127.0.0.1:12399 --stability.level=experimental >"$work/alloy.log" 2>&1 &
pid=$!
for _ in $(seq 50); do curl -sf "http://127.0.0.1:12399/-/ready" >/dev/null && break; sleep 0.2; done
curl -sf "http://127.0.0.1:12399/-/ready" >/dev/null || { echo "alloy failed to start:" >&2; cat "$work/alloy.log" >&2; exit 1; }

levels=(trace debug info warn error)
for lvl in "${levels[@]}"; do
  now=$(date +%s%N)
  python3 - "$lvl" "$N" "$now" >"$work/push-$lvl.json" <<'PY'
import json, sys
lvl, n, now = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
print(json.dumps({"streams": [{"stream": {"level": lvl, "job": "e2e"},
  "values": [[str(now + i), f"{lvl} line {i}"] for i in range(n)]}]}))
PY
  curl -sf -H 'Content-Type: application/json' --data-binary @"$work/push-$lvl.json" \
    "http://127.0.0.1:$PUSH_PORT/loki/api/v1/push"
done
sleep 3

printf '\n%-6s %8s %8s %8s\n' level sent kept ratio
for lvl in "${levels[@]}"; do
  kept=$(grep -c "\"$lvl line " "$work/alloy.log" || true)
  printf '%-6s %8d %8d %8.3f\n' "$lvl" "$N" "$kept" "$(echo "$kept/$N" | bc -l)"
done
echo; echo "--- drop counters"
curl -s http://127.0.0.1:12399/metrics | grep -E '^loki_process_dropped_lines_total' || echo "(none)"
