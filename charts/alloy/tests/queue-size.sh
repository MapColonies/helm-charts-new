#!/usr/bin/env bash
# Asserts on the exporter queue_size, which only the Deployment has: sized from its memory limit
# (limit * memory_share / (send_batch_max_size * bytes_per_record)), 2000 without a limit, and
# exporter.sending_queue.queue_size as is when set. A full queue must drop, not block.
source "$(dirname "$0")/lib.sh"

# expect <queue_size> [helm template args...]
expect() {
  local got case=${*:2}
  got=$(config "$DEPLOYMENT_CONFIG" "${@:2}" | sed -n 's/^ *queue_size *= *//p')
  [[ $got == "$1" ]] || fail "${case:-defaults}: expected queue_size $1, got $got"
}
limit=alloy.alloy.resources.limits.memory

# defaults: no memory limit set
expect 2000
# 1Gi * 0.5 / (4096 * 1024 B), in any Kubernetes memory unit
expect 128 --set $limit=1Gi
expect 64 --set $limit=512Mi
expect 192 --set $limit=1.5Gi
expect 119 --set $limit=1G
expect 128 --set $limit=1073741824
# the batch size, memory share and record size all scale it
expect 256 --set $limit=1Gi --set batching.send_batch_max_size=2048
expect 64 --set $limit=1Gi --set exporter.sending_queue.memory_share=0.25
expect 64 --set $limit=1Gi --set exporter.sending_queue.bytes_per_record=2048
# never below one batch
expect 1 --set $limit=1Mi
# an explicit queue_size wins
expect 300 --set $limit=1Gi --set exporter.sending_queue.queue_size=300
# the StatefulSet's memory limit doesn't count: it has no exporter
expect 2000 --set alloy-logs.alloy.resources.limits.memory=1Gi
config "$STATEFULSET_CONFIG" | grep -q 'otelcol.exporter' && fail "the StatefulSet must not have an exporter"

# a full queue drops new batches instead of blocking the pipeline
config "$DEPLOYMENT_CONFIG" | grep -q '^ *block_on_overflow = false$' || fail "block_on_overflow must be false"

# an unparsable memory limit fails the render
if err=$(render --set $limit=1GB 2>&1 >/dev/null); then
  fail "a memory limit of 1GB must fail the render"
fi
grep -qF '"1GB" is not a memory quantity' <<<"$err" || fail "unexpected error for 1GB: $err"

echo "OK"
