#!/usr/bin/env bash
# Asserts on the rendered config.alloy: sampling.log adds one stage.sampling per
# level with rate < 1, inside loki.process, and rejects values outside [0, 1].
set -uo pipefail
cd "$(dirname "$0")/.."

render() { helm template alloy . "$@" 2>&1 | sed -n '/config.alloy: |-/,$p'; }
errors=0
fail() { echo "FAIL: $1" >&2; errors=$((errors + 1)); }
rejects() { helm template alloy . "$@" >/dev/null 2>&1 && fail "should reject: $*"; }
accepts() { helm template alloy . "$@" >/dev/null 2>&1 || fail "should accept: $*"; }

# 1. per-level stage with the configured rate; rate 1 renders nothing
out=$(render -f tests/values-sampling.yaml)
grep -qF 'selector = "{level=\"trace\"}"' <<<"$out" || fail "trace stage missing"
grep -qF 'rate = 0.25' <<<"$out" || fail "debug rate 0.25 missing"
grep -qF 'drop_counter_reason = "warn_sampled"' <<<"$out" || fail "warn drop reason missing"
grep -qF '{level=\"info\"}' <<<"$out" && fail "rate 1 must not render a stage"

# 2. sampling stages sit inside loki.process, before the OTel receiver
awk '/loki.process "limit_time"/{p=NR} /stage.sampling/{s=NR} /otelcol.receiver.loki "default"/{r=NR} END{exit !(p && s && p<s && s<r)}' <<<"$out" \
  || fail "sampling stages must be inside loki.process, before otelcol.receiver.loki"

# 3. range validation
rejects --set-json 'sampling.log={"info":1.5}'
rejects --set-json 'sampling.log={"info":-0.1}'
rejects --set-json 'sampling.log={"info":"0.5"}'

# 4. integers given via --set (int64) are valid numbers
accepts --set sampling.log.info=0
accepts --set sampling.log.info=1

# 5. setting sampling to null must not crash the render
accepts --set-json 'sampling=null'

[ "$errors" -eq 0 ] && echo "OK" || { echo "$errors check(s) failed"; exit 1; }
