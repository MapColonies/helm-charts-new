#!/usr/bin/env bash
# Runs both rendered configs in the real Alloy binary: `alloy validate`, then `alloy run` against a
# fake Kubernetes API, where every component must report healthy. That also runs the component
# argument checks validate skips, like queue_size > 0.
# Usage: ALLOY=/path/to/alloy tests/configs-e2e.sh [helm template args...]
source "$(dirname "$0")/lib.sh"
: "${ALLOY:?set ALLOY to the alloy binary path}"
API_PORT=${API_PORT:-3592}
HTTP_PORT=${HTTP_PORT:-12340}
work=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; wait; rm -rf "$work"' EXIT

cat >"$work/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: fake, cluster: {server: "http://127.0.0.1:$API_PORT"}}]
users: [{name: fake, user: {}}]
contexts: [{name: fake, context: {cluster: fake, user: fake}}]
current-context: fake
EOF
python3 tests/fake-kube-api.py "$API_PORT" 3 "$work/since" 2>/dev/null &
pids+=($!)

for name in "$OTLP_CONFIG" "$LOGS_CONFIG"; do
  config "$name" "$@" >"$work/$name.alloy"
  "$ALLOY" validate --stability.level=experimental "$work/$name.alloy" >"$work/$name.validate" 2>&1 \
    || { cat "$work/$name.validate" >&2; fail "$name: alloy validate failed"; }

  # Out of a cluster, point the Kubernetes clients at the fake API instead of the in-cluster one
  sed -e "s|^discovery.kubernetes \"pod\" {|&\n    kubeconfig_file = \"$work/kubeconfig\"|" \
      -e "s|^loki.source.kubernetes \"pod_logs\" {|&\n    client { kubeconfig_file = \"$work/kubeconfig\" }|" \
      -e 's|^otelcol.processor.k8sattributes "\(.*\)" {|&\n    auth_type = "kubeConfig"|' \
      "$work/$name.alloy" >"$work/$name.run.alloy"
  KUBECONFIG=$work/kubeconfig "$ALLOY" run "$work/$name.run.alloy" --storage.path="$work/data-$name" \
    --server.http.listen-addr="127.0.0.1:$HTTP_PORT" --stability.level=experimental >"$work/$name.log" 2>&1 &
  pid=$!
  for _ in $(seq 50); do curl -sf "http://127.0.0.1:$HTTP_PORT/-/ready" >/dev/null && break; sleep 0.2; done
  curl -sf "http://127.0.0.1:$HTTP_PORT/-/ready" >/dev/null || { cat "$work/$name.log" >&2; fail "$name: alloy did not start"; }

  unhealthy=$(curl -sf "http://127.0.0.1:$HTTP_PORT/api/v0/web/components" | python3 -c 'import json, sys
for c in json.load(sys.stdin):
    if c["health"]["state"] != "healthy":
        print(c["localID"], c["health"]["state"], c["health"].get("message", ""))')
  [[ -z $unhealthy ]] || fail "$name: unhealthy components: $unhealthy"
  echo "  $name: $(grep -c '^[a-z][a-z0-9_.]* "[^"]*" {' "$work/$name.alloy") components healthy"

  kill "$pid"; wait "$pid" 2>/dev/null || true
done

echo "OK"
