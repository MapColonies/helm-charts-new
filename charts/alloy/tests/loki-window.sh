#!/usr/bin/env bash
# Asserts on the pod logs pipeline's age filter: older_than is maxLogAge, and a line just under
# maxLogAge still reaches Loki within its out-of-order window, max_chunk_age/2 of the Loki chart
# (charts/loki), after the longest delivery delay: the batch timeout plus the exporter's retry
# max_elapsed_time. A shorter maxLogAge is fine.
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
# setting <attribute> [helm template args...]: a quoted attribute's value in the pod logs config
setting() { config "$LOGS_CONFIG" "${@:2}" | sed -n "s/^ *$1 *= *\"\(.*\)\"$/\1/p" | head -1; }

# 1. older_than is maxLogAge as is
[[ $(setting older_than --set maxLogAge=5m) == 5m ]] || fail "older_than must be maxLogAge"

# 2. maxLogAge plus the delivery delay fits in Loki's out-of-order window (its chart default is 2h when unset)
loki=../loki
ls "$loki"/charts/*.tgz >/dev/null 2>&1 || helm dependency build "$loki" >/dev/null
max_chunk_age=$(helm template loki "$loki" --set loki.loki.storage.bucketNames.chunks=c \
  --set loki.loki.storage.bucketNames.ruler=r --set loki.loki.storage.bucketNames.admin=a \
  | sed -n 's/^ *max_chunk_age: *//p' | sort -u)
max_chunk_age=${max_chunk_age:-2h}
[[ $(wc -l <<<"$max_chunk_age") == 1 ]] || fail "Loki renders more than one max_chunk_age: $max_chunk_age"
window=$(($(seconds "$max_chunk_age") / 2))
max_log_age=$(setting older_than "$@")
delay=$(($(seconds "$(setting timeout "$@")") + $(seconds "$(setting max_elapsed_time "$@")")))
(($(seconds "$max_log_age") + delay <= window)) \
  || fail "maxLogAge $max_log_age plus up to ${delay}s of delivery (batch timeout + retry max_elapsed_time) exceeds Loki's out-of-order window, ${window}s (max_chunk_age $max_chunk_age / 2); keep maxLogAge at most $((window - delay))s"

echo "OK"
