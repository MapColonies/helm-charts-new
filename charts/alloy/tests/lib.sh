# Sourced by the tests: runs from the chart directory and renders the chart. Needs helm and yq (v4).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

OTLP_CONFIG=infra-alloy      # ConfigMap of the Deployment that receives OTLP
LOGS_CONFIG=infra-alloy-logs # ConfigMap of the StatefulSet that collects pod logs

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
