#!/usr/bin/env bash
# Runs the rendered loki.source.kubernetes block in real, clustered Alloy instances against a fake
# Kubernetes API: two replicas, then a third joins the way the StatefulSet scales up. Each pod must
# end up tailed by exactly one replica, and every replica must get a share.
# Usage: ALLOY=/path/to/alloy tests/clustering-e2e.sh
source "$(dirname "$0")/lib.sh"
: "${ALLOY:?set ALLOY to the alloy binary path}"
PODS=${PODS:-30}
API_PORT=${API_PORT:-3593}
BASE_PORT=${BASE_PORT:-12350}
work=$(mktemp -d)
pids=()
# wait for the replicas to exit, so a rerun does not reach a replica that is still shutting down
trap 'kill "${pids[@]}" 2>/dev/null || true; wait; rm -rf "$work"' EXIT

# The rendered component block, with fake pods as targets, the fake API as client and loki.echo as output
source_block=$(block 'loki.source.kubernetes "pod_logs"' "$(config "$LOGS_CONFIG")")
grep -q 'clustering {' <<<"$source_block" || fail "rendered block has no clustering"
targets=$(for i in $(seq "$PODS"); do
  printf '{"__meta_kubernetes_namespace"="ns","__meta_kubernetes_pod_name"="pod-%s","__meta_kubernetes_pod_container_name"="app","__meta_kubernetes_pod_uid"="uid-%s"},' "$i" "$i"
done)
sed -e "s|^\( *targets *=\).*|\1 [$targets]\n    client { api_server = \"http://127.0.0.1:$API_PORT\" }|" \
    -e 's|^\( *forward_to *=\).*|\1 [loki.echo.out.receiver]|' <<<"$source_block" >"$work/config.alloy"
echo 'loki.echo "out" {}' >>"$work/config.alloy"

python3 tests/fake-kube-api.py "$API_PORT" 3 "$work/since" 2>/dev/null &
pids+=($!)

start() {
  local port=$((BASE_PORT + $1))
  "$ALLOY" run "$work/config.alloy" --storage.path="$work/data-$1" \
    --server.http.listen-addr="127.0.0.1:$port" --cluster.enabled --cluster.node-name="replica-$1" \
    --cluster.advertise-address="127.0.0.1:$port" --cluster.join-addresses="127.0.0.1:$BASE_PORT" \
    >"$work/replica-$1.log" 2>&1 &
  pids+=($!)
  # wait for it to serve before the next replica tries to join it
  for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/-/ready" >/dev/null && return; sleep 0.2; done
  cat "$work/replica-$1.log" >&2; fail "replica-$1 did not start"
}
# targets <replica>: the pods the replica is tailing right now, from its component debug info
targets() {
  curl -sf "http://127.0.0.1:$((BASE_PORT + $1))/api/v0/web/components/loki.source.kubernetes.pod_logs" \
    | python3 -c 'import json, sys
for t in json.load(sys.stdin).get("debugInfo") or []:
    for a in t["body"]:
        if a["name"] == "labels":
            print(next(l["value"]["value"] for l in a["value"]["value"] if l["key"] == "instance"))'
}
# settled <replicas...>: every pod tailed by exactly one replica, every replica has some
settled() {
  local all=() n
  for r in "$@"; do
    mapfile -t n < <(targets "$r" 2>/dev/null) || return 1
    ((${#n[@]} > 0)) || return 1
    all+=("${n[@]}")
  done
  ((${#all[@]} == PODS)) && (($(printf '%s\n' "${all[@]}" | sort -u | wc -l) == PODS))
}
check() {
  for _ in $(seq 60); do settled "$@" && break; sleep 0.5; done
  settled "$@" || { for r in "$@"; do echo "replica-$r: $(targets "$r" 2>/dev/null | wc -l) pods"; done >&2; fail "pods not split one replica each"; }
  for r in "$@"; do echo "  replica-$r tails $(targets "$r" | wc -l) of $PODS pods"; done
}

start 0; start 1
echo "2 replicas:"; check 0 1
start 2
echo "after scaling up to 3:"; check 0 1 2

echo "OK"
