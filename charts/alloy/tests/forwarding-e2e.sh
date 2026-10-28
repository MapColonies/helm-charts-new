#!/usr/bin/env bash
# Runs both rendered configs in the real Alloy binary, end to end: the StatefulSet's discovers and
# tails a pod through a fake Kubernetes API and forwards its lines to the Deployment's, which
# processes them and exports them to a fake OTLP/HTTP receiver. Checks what arrives: JSON lines
# parsed, the pod's stream labels as resource attributes, a plain line as is with its own
# timestamp, and health checks and lines older than maxLogAge dropped.
# Then a pod writing a line a second: the StatefulSet is killed (kill -9) mid-stream and restarted
# on its storage, and every line must still arrive (at least once). And a crash while the
# Deployment is down: it loses only what the StatefulSet read ahead into its small send queue.
# Usage: ALLOY=/path/to/alloy tests/forwarding-e2e.sh
source "$(dirname "$0")/lib.sh"
: "${ALLOY:?set ALLOY to the alloy binary path}"
API_PORT=${API_PORT:-3590}
OTLP_PORT=${OTLP_PORT:-3589}
PUSH_PORT=${PUSH_PORT:-3588}
HTTP_PORT=${HTTP_PORT:-12320}
work=$(mktemp -d)
pids=()
declare -A pid # by name
trap 'kill "${pids[@]}" 2>/dev/null || true; wait; rm -rf "$work"' EXIT

kubeconfig "$work/kubeconfig" "$API_PORT"
cat >"$work/lines" <<'LINES'
900 too old: older than maxLogAge
60 {"Body":"hello json","SeverityText":"WARN","SeverityNumber":13,"Attributes":{"url.path":"/api/items","user":"u1"}}
50 {"Body":"health check","SeverityText":"INFO","SeverityNumber":9,"Attributes":{"url.path":"/health"}}
40 plain line
LINES

# The Deployment exports to the fake receiver as JSON, and receives the pod logs on PUSH_PORT
config "$DEPLOYMENT_CONFIG" --set 'namespaces[0]=ns' --set "exporter.endpoint=http://127.0.0.1:$OTLP_PORT" \
  | fake_api_clients "$work/kubeconfig" \
  | sed -e "s|^\( *listen_port *=\).*|\1 $PUSH_PORT|" \
        -e 's|^otelcol.exporter.otlphttp "default" {|&\n    encoding = "json"|' >"$work/deployment.alloy"
# The StatefulSet tails ns/pod and forwards to the Deployment on PUSH_PORT
config "$STATEFULSET_CONFIG" --set 'namespaces[0]=ns' | fake_api_clients "$work/kubeconfig" \
  | sed "s|^\( *url *=\).*|\1 \"http://127.0.0.1:$PUSH_PORT/loki/api/v1/push\"|" >"$work/statefulset.alloy"
grep -q "listen_port *= $PUSH_PORT" "$work/deployment.alloy" || fail "could not point the Deployment at PUSH_PORT"
grep -q "127.0.0.1:$PUSH_PORT" "$work/statefulset.alloy" || fail "could not point the StatefulSet at PUSH_PORT"

# run <name> <http port offset> [storage]: start Alloy on a config (storage defaults to its name)
# and wait for it to serve
run() {
  local port=$((HTTP_PORT + $2))
  KUBECONFIG=$work/kubeconfig "$ALLOY" run "$work/$1.alloy" --storage.path="$work/data-${3:-$1}" \
    --server.http.listen-addr="127.0.0.1:$port" --stability.level=experimental >>"$work/$1.log" 2>&1 &
  pid[$1]=$!
  pids+=($!)
  for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/-/ready" >/dev/null && return; sleep 0.2; done
  cat "$work/$1.log" >&2; fail "$1 did not start"
}

start=$(date +%s)
python3 tests/fake-kube-api.py "$API_PORT" "$work/lines" "$work/requests" 2>/dev/null &
pid[api]=$!
pids+=($!)
python3 tests/fake-otlp-receiver.py "$OTLP_PORT" "$work/exported" 2>/dev/null &
pids+=($!)
run deployment 0
run statefulset 1

# stop <name> [signal]: stop that Alloy, gracefully unless a signal is given
stop() { kill "-${2:-TERM}" "${pid[$1]}"; wait "${pid[$1]}" 2>/dev/null || true; }

# exported <what>: wait for the lines to be exported, then check them
exported() {
  for _ in $(seq 150); do grep -q 'plain line' "$work/exported" 2>/dev/null && break; sleep 0.2; done
  grep -q 'plain line' "$work/exported" 2>/dev/null || { tail -n 20 "$work"/*.log >&2; fail "$1: nothing exported"; }
  sleep 2 # let any line that should have been dropped arrive, if it would
  check "$work/exported" || fail "$1"
  mv "$work/exported" "$work/exported-$(date +%s%N)"
}

check() {
python3 - "$1" "$((start - 40))" <<'CHECK'
import json, sys

def value(v):
    return next(iter(v.values())) if v else None

records = []
for line in open(sys.argv[1]):
    for rl in json.loads(line).get("resourceLogs", []):
        resource = {a["key"]: value(a["value"]) for a in rl.get("resource", {}).get("attributes", [])}
        for sl in rl.get("scopeLogs", []):
            for lr in sl.get("logRecords", []):
                attributes = {a["key"]: value(a["value"]) for a in lr.get("attributes", [])}
                # loki.source.kubernetes keeps each line's newline (as before this pipeline was split)
                records.append((value(lr.get("body")).rstrip("\n"), lr, attributes, resource))

def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)

bodies = sorted(set(r[0] for r in records)) # at least once: a resume repeats the last line it read
if bodies != ["hello json", "plain line"]:
    fail(f"expected exactly the JSON and the plain line, got {bodies}")
for body, lr, attributes, resource in records:
    expected = {"k8s.namespace.name": "ns", "k8s.pod.name": "pod", "k8s.container.name": "app",
                "k8s.deployment.name": "app", "owner": "team-a"}
    missing = {k: v for k, v in expected.items() if resource.get(k) != v}
    if missing:
        fail(f"{body}: stream labels missing from resource attributes: {missing}, got {resource}")
    if body == "hello json":
        if lr.get("severityText") != "WARN" or str(lr.get("severityNumber")) not in ("13", "SEVERITY_NUMBER_WARN"):
            fail(f"JSON line severity not parsed: {lr.get('severityText')} {lr.get('severityNumber')}")
        if attributes.get("url.path") != "/api/items" or attributes.get("user") != "u1":
            fail(f"JSON line attributes not parsed: {attributes}")
    if body == "plain line":
        seconds = int(lr.get("timeUnixNano", 0)) / 1e9
        if abs(seconds - int(sys.argv[2])) > 5:
            fail(f"plain line lost its own timestamp: {seconds}, expected ~{sys.argv[2]}")
print("  exported: the JSON line parsed, the plain line as is with its own timestamp, stream labels as resource")
print("  attributes; the health check and the line older than maxLogAge dropped")
CHECK
}

exported "forwarding"

# 2. a pod writing a line a second; the StatefulSet is killed mid-stream and restarted on its storage
stop statefulset
kill "${pid[api]}"; wait "${pid[api]}" 2>/dev/null || true
for i in $(seq 1 30); do echo "-$i live $i"; done >"$work/live-lines"
python3 tests/fake-kube-api.py "$API_PORT" "$work/live-lines" "$work/requests" 2>/dev/null &
pid[api]=$!
pids+=($!)
run statefulset 1 statefulset-crash
sleep 12
stop statefulset KILL
run statefulset 1 statefulset-crash
for _ in $(seq 150); do grep -q '"live 30' "$work/exported" 2>/dev/null && break; sleep 0.2; done
missing=$(for i in $(seq 1 30); do grep -q "\"live $i\\\\n\"" "$work/exported" 2>/dev/null || echo -n "$i "; done)
[[ -z $missing ]] || fail "lines lost across a kill -9 of the StatefulSet: live $missing"
echo "  killed mid-stream and restarted: all 30 lines arrived"

# 3. the Deployment is down; the StatefulSet reads 80 lines of 32KB (2.5MB) and is killed. Positions
# are saved once a line is queued for sending, so what's queued is lost; the 256KiB send queue must
# stop it reading ahead (Alloy's default queue would hold all of them), and the rest must arrive.
stop statefulset
stop deployment
kill "${pid[api]}"; wait "${pid[api]}" 2>/dev/null || true
pad=$(head -c 32000 /dev/zero | tr '\0' x)
for i in $(seq 1 80); do echo "$((200 - i)) big $i $pad"; done >"$work/big-lines"
python3 tests/fake-kube-api.py "$API_PORT" "$work/big-lines" "$work/requests" 2>/dev/null &
pid[api]=$!
pids+=($!)
run statefulset 1 statefulset-outage
sleep 15 # read until the queue is full, and save the position (every 10s)
stop statefulset KILL
run deployment 0
run statefulset 1 statefulset-outage
for _ in $(seq 150); do grep -q '"big 80 ' "$work/exported" 2>/dev/null && break; sleep 0.2; done
python3 - "$work/exported" <<'BOUND' || fail "crash during a Deployment outage"
import json, re, sys
got = set()
for line in open(sys.argv[1]):
    for rl in json.loads(line).get("resourceLogs", []):
        for sl in rl.get("scopeLogs", []):
            for lr in sl.get("logRecords", []):
                m = re.match(r"big (\d+) ", next(iter(lr["body"].values())))
                if m:
                    got.add(int(m.group(1)))
lost = [i for i in range(1, 81) if i not in got]
if len(lost) > 40:
    sys.exit(f"FAIL: {len(lost)} of 80 lines lost; the send queue let the StatefulSet read too far ahead")
if lost and set(range(max(lost) + 1, 81)) - got:
    sys.exit(f"FAIL: lines after the read-ahead were lost too: {sorted(set(range(max(lost) + 1, 81)) - got)}")
print(f"  killed while the Deployment was down: lost the {len(lost)} lines it had read ahead (of 80), the rest arrived")
BOUND

echo "OK"
