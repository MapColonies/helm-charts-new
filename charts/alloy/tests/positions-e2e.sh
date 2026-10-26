#!/usr/bin/env bash
# Runs the rendered loki.source.kubernetes block in the real Alloy binary against a fake Kubernetes
# API, stops it and starts it again on the same storage path, the way a StatefulSet replica restarts
# on its PVC. It must resume from its saved read positions instead of re-reading the container log;
# a replica on empty storage (a new PVC) reads it from the start.
# Usage: ALLOY=/path/to/alloy tests/positions-e2e.sh
source "$(dirname "$0")/lib.sh"
: "${ALLOY:?set ALLOY to the alloy binary path}"
LINES=${LINES:-50}
API_PORT=${API_PORT:-3591}
HTTP_PORT=${HTTP_PORT:-12330}
work=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; wait; rm -rf "$work"' EXIT

source_block=$(block 'loki.source.kubernetes "pod_logs"' "$(config "$LOGS_CONFIG")")
[[ -n $source_block ]] || fail "loki.source.kubernetes \"pod_logs\" not rendered"
target='{"__meta_kubernetes_namespace"="ns","__meta_kubernetes_pod_name"="pod","__meta_kubernetes_pod_container_name"="app","__meta_kubernetes_pod_uid"="uid-1"}'
sed -e "s|^\( *targets *=\).*|\1 [$target]\n    client { api_server = \"http://127.0.0.1:$API_PORT\" }|" \
    -e 's|^\( *forward_to *=\).*|\1 [loki.echo.out.receiver]|' <<<"$source_block" >"$work/config.alloy"
echo 'loki.echo "out" {}' >>"$work/config.alloy"

python3 tests/fake-kube-api.py "$API_PORT" "$LINES" "$work/since" 2>/dev/null &
pids+=($!)

# run <name> <storage dir> <seconds>: run Alloy on that storage until it shipped something, then
# <seconds> more, and stop it gracefully, the way a pod is terminated
run() {
  "$ALLOY" run "$work/config.alloy" --storage.path="$2" --server.http.listen-addr="127.0.0.1:$HTTP_PORT" \
    --stability.level=experimental >"$work/$1.log" 2>&1 &
  local pid=$!
  for _ in $(seq 100); do grep -q 'line [0-9]' "$work/$1.log" && break; sleep 0.2; done
  sleep "$3"
  kill "$pid"; wait "$pid" 2>/dev/null || true
}
shipped() { grep -c 'line [0-9]' "$work/$1.log" || true; }

# 1. first start ships the whole log; positions are saved every 10s and on shutdown
run first "$work/pvc" 2
[[ $(shipped first) -eq $LINES ]] || fail "first start shipped $(shipped first) of $LINES lines"
grep -rq 'cursor-ns/pod:app:uid-1' "$work/pvc" || fail "no read position saved under the storage path"

# 2. restart on the same storage resumes: at most the last line again
run restarted "$work/pvc" 2
echo "  restart on the same PVC: re-shipped $(shipped restarted) of $LINES lines (sinceTime $(sed -n "2s/.* //p" "$work/since"))"
[[ $(shipped restarted) -le 1 ]] || fail "restarted replica re-shipped $(shipped restarted) lines"

# 3. control: empty storage reads the whole log again
run fresh "$work/new-pvc" 2
echo "  start on a new PVC:      re-shipped $(shipped fresh) of $LINES lines (sinceTime $(sed -n "3s/.* //p" "$work/since"))"
[[ $(shipped fresh) -eq $LINES ]] || fail "replica on new storage shipped $(shipped fresh) of $LINES lines"

echo "OK"
