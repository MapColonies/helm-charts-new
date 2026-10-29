#!/usr/bin/env bash
# Asserts on the rendered config.alloy: sampling.log is off by default and, when
# set, samples logs by severity_text between the health filter and the batcher.
set -uo pipefail
cd "$(dirname "$0")/.."

render() { helm template alloy . "$@" 2>&1 | sed -n '/config.alloy: |-/,$p'; }
errors=0
fail() { echo "FAIL: $1" >&2; errors=$((errors + 1)); }
rejects() { helm template alloy . "$@" >/dev/null 2>&1 && fail "should reject: $*"; }
accepts() { helm template alloy . "$@" >/dev/null 2>&1 || fail "should accept: $*"; }

# 1. off by default: no sampling components, health filter feeds the batcher
out=$(render)
grep -q 'probabilistic_sampler' <<<"$out" && fail "default render must not contain sampling"
grep -A12 'otelcol.processor.filter "health_filter"' <<<"$out" | grep -qF 'logs = [otelcol.processor.batch.default.input]' \
  || fail "default health_filter must output to the batcher"

# 2. one priority statement per severity with rate < 1, as a percentage, keys lowercased
out=$(render -f tests/values-sampling.yaml)
grep -A6 'otelcol.processor.filter "log_sampling_drop"' <<<"$out" | grep -qF '"ToLowerCase(severity_text) == \"trace\""' || fail "rate 0 must be dropped by log_sampling_drop"
grep -qF 'sampling.priority\"], 0)' <<<"$out" && fail "rate 0 must not use the sampler (it ignores priority 0)"
grep -qF '"set(attributes[\"sampling.priority\"], 25) where ToLowerCase(severity_text) == \"debug\""' <<<"$out" || fail "DEBUG priority missing or not lowercased"
grep -qF '"set(attributes[\"sampling.priority\"], 50) where ToLowerCase(severity_text) == \"warn\""' <<<"$out" || fail "warn priority missing"
grep -qF '== \"info\"' <<<"$out" && fail "rate 1 must not render a statement"

# 3. wiring: health_filter -> drop -> priority -> sampler -> cleanup -> batch
awk '/otelcol.processor.filter "health_filter"/{h=NR} /otelcol.processor.filter.log_sampling_drop.input/{if(h&&!a)a=NR}
     /otelcol.processor.filter "log_sampling_drop"/{d=NR} /otelcol.processor.transform.log_sampling_priority.input/{if(d&&!e)e=NR}
     /otelcol.processor.transform "log_sampling_priority"/{p=NR} /otelcol.processor.probabilistic_sampler "logs"/{s=NR}
     /otelcol.processor.transform "log_sampling_cleanup"/{c=NR} /otelcol.processor.batch "default"/{b=NR}
     END{exit !(h<a && a<d && d<e && e<p && p<s && s<c && c<b)}' <<<"$out" || fail "sampling components wired in the wrong order"
grep -qF 'delete_key(attributes, "sampling.priority")' <<<"$out" || fail "cleanup must remove sampling.priority"
grep -qF 'delete_key(attributes, "sampling.key")' <<<"$out" || fail "cleanup must remove sampling.key"
awk '/otelcol.processor.transform "log_sampling_priority"/{p=1} p && /delete_key\(attributes, "sampling.priority"\)/{if(!d)d=NR} p && /set\(attributes\[\\"sampling.priority/{if(!s)s=NR} END{exit !(d && d<s)}' <<<"$out" \
  || fail "an incoming sampling.priority must be deleted before the severity rates are set"
for attr in sampling.randomness sampling.threshold; do
  grep -qF "delete_key(attributes, \"$attr\")" <<<"$out" || fail "cleanup must remove $attr added by the sampler"
done

# 4. pino JSON severity ("level") is read when there is no SeverityText
out=$(render)
grep -qF '`set(severity_text, cache["level"]) where IsMap(cache) and cache["SeverityText"] == nil and IsString(cache["level"])`' <<<"$out" \
  || fail "pino level must set severity_text"

# 5. only rate 0, or only 0 < rate < 1, skips the other component
out=$(render --set sampling.log.trace=0)
grep -q 'probabilistic_sampler' <<<"$out" && fail "rate 0 alone must not render the sampler"
grep -A12 'otelcol.processor.filter "log_sampling_drop"' <<<"$out" | grep -qF 'logs = [otelcol.processor.batch.default.input]' \
  || fail "drop filter alone must output to the batcher"
out=$(render --set sampling.log.info=0.5)
grep -q 'log_sampling_drop' <<<"$out" && fail "no rate 0 must not render the drop filter"

# 6. a quote in a severity key is escaped, not injected
out=$(render --set-json 'sampling.log={"we\"ird":0.3}')
grep -qF '== \"we\\\"ird\""' <<<"$out" || fail "severity key not escaped"

# 7. validation
rejects --set-json 'sampling.log={"info":1.5}'
rejects --set-json 'sampling.log={"info":-0.1}'
rejects --set sampling.log.info=abc
rejects --set-json 'sampling.log={"info":0.000000001}'
accepts --set-json 'sampling.log={"info":0.0001}'
rejects --set-json 'sampling.log={"info":0.1,"INFO":0.2}'
accepts --set sampling.log.info=0
accepts --set sampling.log.info=1
accepts --set sampling.log.info=0.5
accepts --set-json 'sampling.log={"info":"0.5"}'
accepts --set-json 'sampling=null'

# 8. only the Deployment samples; the StatefulSet just forwards pod logs to it
helm template alloy . -f tests/values-sampling.yaml | yq 'select(.metadata.name == "infra-alloy-logs") | .data["config.alloy"]' \
  | grep -qE 'sampling|severity_text' && fail "the pod logs StatefulSet config must not sample"

[ "$errors" -eq 0 ] && echo "OK" || { echo "$errors check(s) failed"; exit 1; }
