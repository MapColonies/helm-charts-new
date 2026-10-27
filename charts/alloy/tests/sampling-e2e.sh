#!/usr/bin/env bash
# Runs the real Alloy binary against the rendered log pipeline (loki.process, OTel parsing,
# health filter and sampling), with the batcher swapped for loki.echo. Pushes N pod-style
# JSON lines per severity and format, with no level label, and checks what survives
# against the sampling.log rates in the chart values: rates 0 and 1 exactly,
# others within 5 standard deviations. Fails on any leftover sampling.* attribute.
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

# Expected keep rates: sampling.log from the merged values, via a throwaway template in a copy of the chart
cp -r . "$work/chart"
echo '{{ (.Values.sampling | default dict).log | default dict | toJson }}' >"$work/chart/templates/zz-sampling-rates.yaml"
helm template alloy "$work/chart" "$@" --show-only templates/zz-sampling-rates.yaml | tail -1 >"$work/rates.json"

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

# Formats (sampling keys are matched case-insensitively):
#   otel: OTel-format JSON, SeverityText upper case, with an app attribute sampling.priority=25
#         that must not override the configured rates
#   pino: pino JSON from js-logger without OTel, lower-case "level"
levels=(trace debug info warn error)
formats=(otel pino)
for lvl in "${levels[@]}"; do
  for fmt in "${formats[@]}"; do
    now=$(date +%s%N)
    python3 - "$lvl" "$fmt" "$N" "$now" >"$work/push-$lvl-$fmt.json" <<'PY'
import json, sys
lvl, fmt, n, now = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
def line(i):
    if fmt == "otel":
        return json.dumps({"Timestamp": str(now + i), "SeverityText": lvl.upper(),
          "Body": f"{lvl}-otel-line-{i}", "Attributes": {"sampling.priority": 25}, "Resource": {}})
    return json.dumps({"level": lvl, "time": (now + i) // 1000000, "msg": f"{lvl}-pino-line-{i}"})
print(json.dumps({"streams": [{"stream": {"job": "e2e"},
  "values": [[str(now + i), line(i)] for i in range(n)]}]}))
PY
    curl -sf -H 'Content-Type: application/json' --data-binary @"$work/push-$lvl-$fmt.json" \
      "http://127.0.0.1:$PUSH_PORT/loki/api/v1/push"
  done
done

# Wait until the output stops growing
prev=-1
for i in $(seq 60); do
  sleep 1
  cur=$(grep -c 'loki.echo.out' "$work/alloy.log" || true)
  [ "$i" -ge 3 ] && [ "$cur" -eq "$prev" ] && break
  prev=$cur
done

failed=0
counts=()
for lvl in "${levels[@]}"; do
  for fmt in "${formats[@]}"; do
    counts+=("$lvl/$fmt=$( (grep -o "$lvl-$fmt-line-[0-9]*" "$work/alloy.log" || true) | sort -u | wc -l)")
  done
done
echo
python3 -I - "$work/rates.json" "$N" "${counts[@]}" <<'PY' || failed=1
import json, math, sys
rates = {k.lower(): float(v) for k, v in json.load(open(sys.argv[1])).items()}
n, failed = int(sys.argv[2]), False
print(f"{'level':6} {'format':6} {'sent':>6} {'kept':>6} {'ratio':>6} {'rate':>6} {'allowed':>11}")
for arg in sys.argv[3:]:
    name, kept = arg.split("=")
    lvl, fmt = name.split("/")
    kept, p = int(kept), rates.get(lvl, 1.0)
    # rates 0 and 1 are exact; otherwise allow 5 standard deviations of binomial(n, p)
    margin = 5 * math.sqrt(n * p * (1 - p))
    lo, hi = math.ceil(n * p - margin), math.floor(n * p + margin)
    ok = lo <= kept <= hi
    failed |= not ok
    print(f"{lvl:6} {fmt:6} {n:6} {kept:6} {kept / n:6.3f} {p:6g} {f'{lo}-{hi}':>11}  {'ok' if ok else 'FAIL'}")
sys.exit(failed)
PY

# Without sampling configured, the app's own sampling.priority attribute passes through untouched
echo; echo "--- output lines with leftover sampling attributes (expect none)"
if [ "$(cat "$work/rates.json")" = "{}" ]; then
  echo "(skipped: sampling.log is empty)"
elif grep 'loki.echo' "$work/alloy.log" | grep 'sampling\.' | head -3; then
  failed=1
else
  echo "(none)"
fi
echo; echo "--- example output lines"
grep 'loki.echo' "$work/alloy.log" | grep -m1 'error-otel-line-' || true
grep 'loki.echo' "$work/alloy.log" | grep -m1 'error-pino-line-' || true
echo; echo "--- sampler metrics"
curl -s http://127.0.0.1:12399/metrics | grep -E '^otelcol_processor_probabilistic_sampler' || echo "(none)"
echo; echo "--- alloy errors"
grep -iE 'level=(error|warn)' "$work/alloy.log" | head -5 || echo "(none)"

echo
[ "$failed" -eq 0 ] && echo "OK" || { echo "FAIL"; exit 1; }
