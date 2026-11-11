# Sourced by the tests: runs from the chart directory and renders the chart. Needs helm and yq (v4).
set -euo pipefail
# A failing command inside $(...) fails the substitution too, so assigning its result stops the test
shopt -s inherit_errexit
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DEPLOYMENT_CONFIG=infra-alloy       # the Deployment's: receives OTLP and the pod logs, processes, exports
STATEFULSET_CONFIG=infra-alloy-logs # the StatefulSet's: tails pod logs, forwards them to the Deployment

fail() { echo "FAIL: $1" >&2; exit 1; }
# Kubernetes 1.27 enables StatefulSet PVC retention policies by default
render() { helm template alloy . --kube-version 1.27.0 "$@"; }
# config <ConfigMap name> [helm template args...]: that ConfigMap's config.alloy
config() {
  local name=$1; shift
  render "$@" | N=$name yq 'select(.kind == "ConfigMap" and .metadata.name == env(N)) | .data["config.alloy"]'
}
# block <component> <config>: the component's top-level block, e.g. block 'loki.source.kubernetes "pod_logs"'
block() { sed -n "/^$1 {/,/^}\$/p" <<<"$2"; }

# kubeconfig <file> <port>: writes a kubeconfig for tests/fake-kube-api.py on that port
kubeconfig() {
  printf '%s\n' 'apiVersion: v1' 'kind: Config' \
    "clusters: [{name: fake, cluster: {server: \"http://127.0.0.1:$2\"}}]" \
    'users: [{name: fake, user: {}}]' \
    'contexts: [{name: fake, context: {cluster: fake, user: fake}}]' \
    'current-context: fake' >"$1"
}
# fake_api_clients <kubeconfig>: rewrites a config on stdin so its Kubernetes clients use that
# kubeconfig instead of the in-cluster service account
fake_api_clients() {
  sed -e "s|^discovery.kubernetes \"pod\" {|&\n    kubeconfig_file = \"$1\"|" \
      -e "s|^loki.source.kubernetes \"pod_logs\" {|&\n    client { kubeconfig_file = \"$1\" }|" \
      -e 's|^otelcol.processor.k8sattributes "\(.*\)" {|&\n    auth_type = "kubeConfig"|'
}
