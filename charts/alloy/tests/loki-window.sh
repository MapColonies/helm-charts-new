#!/usr/bin/env bash
# Asserts on the pod logs pipeline's age filter: older_than is maxLogAge, and a line just under
# maxLogAge still reaches Loki within its out-of-order window, max_chunk_age/2 of the Loki chart
# (charts/loki), after the longest delivery delay: the batch timeout, plus the exporter's retry
# max_elapsed_time, plus the client timeout of a last attempt started just before that ends. A
# shorter maxLogAge is fine.
# Usage: tests/loki-window.sh [helm template args...], e.g. -f <site values> to check them too
source "$(dirname "$0")/lib.sh"

# seconds <duration>: seconds in a duration of whole h/m/s parts, like 7m30s or 2h
seconds() {
  local total=0
  [[ -n $1 && $1 =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ ]] || fail "'$1' is not a duration of whole h/m/s parts"
  [[ $1 =~ ([0-9]+)h ]] && total=$((total + BASH_REMATCH[1] * 3600))
  [[ $1 =~ ([0-9]+)m ]] && total=$((total + BASH_REMATCH[1] * 60))
  [[ $1 =~ ([0-9]+)s ]] && total=$((total + BASH_REMATCH[1]))
  echo "$total"
}
# setting <component> <attribute> [helm template args...]: a quoted attribute's value in that
# component's block of the Deployment config
setting() {
  local value
  value=$(block "$1" "$(config "$DEPLOYMENT_CONFIG" "${@:3}")" | sed -n "s/^ *$2 *= *\"\(.*\)\"$/\1/p")
  [[ $(wc -l <<<"$value") == 1 && -n $value ]] || fail "expected one $2 in $1, got: $value"
  echo "$value"
}
batch='otelcol.processor.batch "default"'
exporter='otelcol.exporter.otlphttp "default"'
age_filter='loki.process "limit_time"'

# 1. older_than is maxLogAge as is
[[ $(setting "$age_filter" older_than --set maxLogAge=5m) == 5m ]] || fail "older_than must be maxLogAge"

# 2. maxLogAge plus the delivery delay fits in Loki's out-of-order window (its chart default is 2h when unset)
loki=../loki
ls "$loki"/charts/*.tgz >/dev/null 2>&1 || helm dependency build "$loki" >/dev/null
max_chunk_age=$(helm template loki "$loki" --set loki.loki.storage.bucketNames.chunks=c \
  --set loki.loki.storage.bucketNames.ruler=r --set loki.loki.storage.bucketNames.admin=a \
  | sed -n 's/^ *max_chunk_age: *//p' | sort -u)
max_chunk_age=${max_chunk_age:-2h}
[[ $(wc -l <<<"$max_chunk_age") == 1 ]] || fail "Loki renders more than one max_chunk_age: $max_chunk_age"
window=$(($(seconds "$max_chunk_age") / 2))
max_log_age=$(setting "$age_filter" older_than "$@")
delay=$(($(seconds "$(setting "$batch" timeout "$@")") + $(seconds "$(setting "$exporter" max_elapsed_time "$@")") \
  + $(seconds "$(setting "$exporter" timeout "$@")")))
(($(seconds "$max_log_age") + delay <= window)) \
  || fail "maxLogAge $max_log_age plus up to ${delay}s of delivery (batch timeout + retry max_elapsed_time + client timeout) exceeds Loki's out-of-order window, ${window}s (max_chunk_age $max_chunk_age / 2); keep maxLogAge at most $((window - delay))s"

echo "OK"
