#!/usr/bin/env bash
# Asserts on the exporter queue_size of both configs: sized from each workload's own memory limit
# (limit * memory_share / (send_batch_max_size * bytes_per_record)), 2000 without a limit, and
# exporter.sending_queue.queue_size as is when set. A full queue must drop, not block.
source "$(dirname "$0")/lib.sh"

queue_size() { config "$1" "${@:2}" | sed -n 's/^ *queue_size *= *//p'; }

# expect <otlp queue_size> <logs queue_size> [helm template args...]
expect() {
  local otlp logs case=${*:3}
  otlp=$(queue_size "$OTLP_CONFIG" "${@:3}")
  logs=$(queue_size "$LOGS_CONFIG" "${@:3}")
  [[ $otlp == "$1" && $logs == "$2" ]] \
    || fail "${case:-defaults}: expected queue_size $1 (OTLP) / $2 (logs), got $otlp / $logs"
}

# defaults: the OTLP Deployment sets no memory limit, the StatefulSet 1Gi -> 1Gi * 0.5 / (4096 * 1024 B)
expect 2000 128
# each workload is sized from its own limit, in any Kubernetes memory unit
expect 128 128 --set alloy.alloy.resources.limits.memory=1Gi
expect 2000 64 --set alloy-logs.alloy.resources.limits.memory=512Mi
expect 2000 192 --set alloy-logs.alloy.resources.limits.memory=1.5Gi
expect 2000 119 --set alloy-logs.alloy.resources.limits.memory=1G
expect 2000 128 --set alloy-logs.alloy.resources.limits.memory=1073741824
# the batch size, memory share and record size all scale it
expect 2000 256 --set batching.send_batch_max_size=2048
expect 2000 64 --set exporter.sending_queue.memory_share=0.25
expect 2000 64 --set exporter.sending_queue.bytes_per_record=2048
# never below one batch
expect 2000 1 --set alloy-logs.alloy.resources.limits.memory=1Mi
# an explicit queue_size wins
expect 300 300 --set exporter.sending_queue.queue_size=300

# a full queue drops new batches instead of blocking the pipeline
for name in "$OTLP_CONFIG" "$LOGS_CONFIG"; do
  config "$name" | grep -q '^ *block_on_overflow = false$' || fail "$name: block_on_overflow must be false"
done

# an unparsable memory limit fails the render
if err=$(render --set alloy-logs.alloy.resources.limits.memory=1GB 2>&1 >/dev/null); then
  fail "a memory limit of 1GB must fail the render"
fi
grep -qF '"1GB" is not a memory quantity' <<<"$err" || fail "unexpected error for 1GB: $err"

echo "OK"
