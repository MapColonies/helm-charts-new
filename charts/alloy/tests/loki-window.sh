#!/usr/bin/env bash
# Asserts on the pod logs pipeline's age filter: older_than is maxLogAge, and a line just under
# maxLogAge still reaches Loki within its out-of-order window, max_chunk_age/2 of the Loki chart
# (charts/loki), after the longest delivery delay: the batch timeout, plus the exporter's retry
# max_elapsed_time, plus the client timeout of a last attempt started just before that ends. A
# shorter maxLogAge is fine.
# Usage: tests/loki-window.sh [helm template args...], e.g. -f <site values> to check them too
source "$(dirname "$0")/lib.sh"

# seconds <duration>: seconds in a Go duration, as Alloy parses it: 7m30s, 7.9m, 1.5h, 500ms...
seconds() {
  awk -v d="$1" 'BEGIN {
    u["h"] = 3600; u["m"] = 60; u["s"] = 1; u["ms"] = 1e-3; u["us"] = 1e-6; u["µs"] = 1e-6; u["ns"] = 1e-9
    if (d == "") exit 1
    for (rest = d; rest != ""; rest = substr(rest, RLENGTH + 1)) {
      if (!match(rest, /^([0-9]+\.?[0-9]*|\.[0-9]+)(h|ms|us|µs|ns|m|s)/)) exit 1
      token = substr(rest, 1, RLENGTH)
      number = token; sub(/[a-zµ]+$/, "", number)
      total += number * u[substr(token, length(number) + 1)]
    }
    print total
  }' || fail "'$1' is not a duration"
}
# setting <component> <attribute> [helm template args...]: a quoted attribute's value in that
# component's block of the Deployment config
setting() {
  local deployment value
  deployment=$(config "$DEPLOYMENT_CONFIG" "${@:3}")
  value=$(block "$1" "$deployment" | sed -n "s/^ *$2 *= *\"\(.*\)\"$/\1/p")
  [[ $(wc -l <<<"$value") == 1 && -n $value ]] || fail "expected one $2 in $1, got: $value"
  echo "$value"
}
batch='otelcol.processor.batch "default"'
exporter='otelcol.exporter.otlphttp "default"'
age_filter='loki.process "limit_time"'
# Each value is assigned on its own, so a fail inside $(...) stops the test

# 1. older_than is maxLogAge as is
older_than=$(setting "$age_filter" older_than --set maxLogAge=5m)
[[ $older_than == 5m ]] || fail "older_than must be maxLogAge, got $older_than"

# 2. maxLogAge plus the delivery delay fits in Loki's out-of-order window (its chart default is 2h when unset)
loki=../loki
ls "$loki"/charts/*.tgz >/dev/null 2>&1 || helm dependency build "$loki" >/dev/null
max_chunk_age=$(helm template loki "$loki" --set loki.loki.storage.bucketNames.chunks=c \
  --set loki.loki.storage.bucketNames.ruler=r --set loki.loki.storage.bucketNames.admin=a \
  | sed -n 's/^ *max_chunk_age: *//p' | sort -u)
max_chunk_age=${max_chunk_age:-2h}
[[ $(wc -l <<<"$max_chunk_age") == 1 ]] || fail "Loki renders more than one max_chunk_age: $max_chunk_age"
chunk_age_seconds=$(seconds "$max_chunk_age")
max_log_age=$(setting "$age_filter" older_than "$@")
max_log_age_seconds=$(seconds "$max_log_age")
batch_timeout=$(seconds "$(setting "$batch" timeout "$@")")
retries=$(seconds "$(setting "$exporter" max_elapsed_time "$@")")
client_timeout=$(seconds "$(setting "$exporter" timeout "$@")")
read -r window delay limit fits < <(awk -v c="$chunk_age_seconds" -v a="$max_log_age_seconds" \
  -v b="$batch_timeout" -v r="$retries" -v t="$client_timeout" \
  'BEGIN { w = c / 2; d = b + r + t; print w, d, w - d, (a + d <= w) ? "yes" : "no" }')
[[ $fits == yes ]] \
  || fail "maxLogAge $max_log_age plus up to ${delay}s of delivery (batch timeout + retry max_elapsed_time + client timeout) exceeds Loki's out-of-order window, ${window}s (max_chunk_age $max_chunk_age / 2); keep maxLogAge at most ${limit}s"

echo "OK"
