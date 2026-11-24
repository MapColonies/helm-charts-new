#!/usr/bin/env bash
# Render assertions for the provisioning sidecars: image tag and one health port per sidecar.
# Run from charts/grafana: tests/sidecars.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
out=$(helm template t . --namespace infra --show-only charts/grafana/templates/deployment.yaml)

# containers: name, image and HEALTH_PORT of each sidecar
sidecars=$(yq -r '.spec.template.spec.containers[] | select(.name | test("-sc-")) |
  .name + " " + .image + " " + ((.env // [])[] | select(.name == "HEALTH_PORT") | .value)' <<<"$out")

for sc in sc-alerts sc-dashboard sc-datasources; do
  grep -q -- "-$sc " <<<"$sidecars" || fail "$sc container missing"
done

# 1. every sidecar runs the pinned k8s-sidecar tag
[ "$(grep -c 'k8s-sidecar:2.14.3 ' <<<"$sidecars")" = 3 ] || fail "all 3 sidecars must use k8s-sidecar:2.14.3"

# 2. the health ports are set and distinct (8080 dashboards, 8081 alerts, 8082 datasources)
grep -q -- '-sc-dashboard .* 8080$' <<<"$sidecars" || fail "sc-dashboard must use HEALTH_PORT 8080"
grep -q -- '-sc-alerts .* 8081$' <<<"$sidecars" || fail "sc-alerts must use HEALTH_PORT 8081"
grep -q -- '-sc-datasources .* 8082$' <<<"$sidecars" || fail "sc-datasources must use HEALTH_PORT 8082"
[ "$(awk '{print $3}' <<<"$sidecars" | sort -u | wc -l | tr -d ' ')" = 3 ] || fail "health ports must be distinct"

echo PASS
