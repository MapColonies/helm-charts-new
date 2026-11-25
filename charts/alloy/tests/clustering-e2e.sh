#!/usr/bin/env bash
# Runs the rendered loki.source.kubernetes block in real, clustered Alloy instances against a fake
# Kubernetes API: two replicas, then a third joins the way the StatefulSet scales up. Each pod must
# end up tailed by exactly one replica, and every replica must get a share. Then the third restarts,
# as in a rollout or an eviction, and the test records what that costs: its peers take over its pods
# without its read positions and read them from the start; once it's back it resumes them from its
# own saved positions (re-sending what the peers shipped meanwhile); and until the peers drop its
# old membership (~30s), they keep tailing its pods too, so those lines are shipped twice.
# Usage: ALLOY=/path/to/alloy tests/clustering-e2e.sh
source "$(dirname "$0")/lib.sh"
: "${ALLOY:?set ALLOY to the alloy binary path}"
PODS=${PODS:-30}
API_PORT=${API_PORT:-3593}
BASE_PORT=${BASE_PORT:-12350}
work=$(mktemp -d)
pids=()
pid=() # by replica
# wait for the replicas to exit, so a rerun does not reach a replica that is still shutting down
trap 'kill "${pids[@]}" 2>/dev/null || true; wait; rm -rf "$work"' EXIT

# The rendered component block, with fake pods as targets, the fake API as client and loki.echo as output
source_block=$(block 'loki.source.kubernetes "pod_logs"' "$(config "$STATEFULSET_CONFIG")")
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
  pid[$1]=$!
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
# check <replicas...>: wait up to $WAIT seconds (default 30) for the pods to be split between them
check() {
  for _ in $(seq $((${WAIT:-30} * 2))); do settled "$@" && break; sleep 0.5; done
  settled "$@" || { for r in "$@"; do echo "replica-$r: $(targets "$r" 2>/dev/null | wc -l) pods"; done >&2; fail "pods not split one replica each"; }
  for r in "$@"; do echo "  replica-$r tails $(targets "$r" | wc -l) of $PODS pods"; done
}

# stop <replica>: terminate it gracefully, the way a pod is, so it saves its positions and leaves
stop() { kill "${pid[$1]}"; wait "${pid[$1]}" 2>/dev/null || true; }
# since <line> <pod>: the sinceTime of the pod's last log request after that line of the request
# record, waiting up to 15s for one ("none" when read from the start)
since() {
  local s
  for _ in $(seq 75); do
    s=$(tail -n "+$(($1 + 1))" "$work/since" | awk -v pod="$2" '$1 == pod { s = $2 } END { print s }')
    [[ -n $s ]] && break
    sleep 0.2
  done
  echo "${s:-no request}"
}

start 0; start 1
echo "2 replicas:"; check 0 1
start 2
echo "after scaling up to 3:"; check 0 1 2

mapfile -t moved < <(targets 2 | sed 's/:app$//' | sort)
# before it restarts, replica-2 has read its pods and saved their positions (synced every 10s)
saved() { cat "$work"/data-2/loki.source.kubernetes.pod_logs/positions.yml 2>/dev/null; }
for _ in $(seq 75); do
  missing=0
  for pod in "${moved[@]}"; do grep -qF "cursor-$pod:" <<<"$(saved)" || missing=1; done
  ((missing)) || break
  sleep 0.2
done
((missing == 0)) || fail "replica-2 did not save the positions of its pods"
mark=$(wc -l <"$work/since")
stop 2
echo "replica-2 restarting:"; check 0 1
for pod in "${moved[@]}"; do
  [[ $(since "$mark" "$pod") == none ]] || fail "$pod: expected the peer taking it over to read it from the start, got $(since "$mark" "$pod")"
done
echo "  its ${#moved[@]} pods were read from the start by the peers that took them over"

mark=$(wc -l <"$work/since")
back=$SECONDS
start 2
echo "replica-2 back:"; WAIT=90 check 0 1 2
echo "  its pods were tailed by it and by the peers for $((SECONDS - back))s, until the peers dropped its old membership"
[[ $(targets 2 | sed 's/:app$//' | sort) == "$(printf '%s\n' "${moved[@]}")" ]] || fail "replica-2 did not get its pods back"
for pod in "${moved[@]}"; do
  [[ $(since "$mark" "$pod") != none && $(since "$mark" "$pod") != "no request" ]] \
    || fail "$pod: expected replica-2 to resume from its saved position, got $(since "$mark" "$pod")"
done
echo "  and replica-2 resumed them from its saved positions"

echo "OK"
