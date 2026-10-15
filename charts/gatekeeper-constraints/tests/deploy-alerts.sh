#!/usr/bin/env bash
# Asserts on the rendered deploy-alert ConfigMap: off by default, namespace scope
# follows workloadPolicies, plain-text annotations.
set -euo pipefail
cd "$(dirname "$0")/.."

render() { helm template gatekeeper-constraints . -n gatekeeper-system "$@"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
on=(--set deployAlerts.enabled=true)
ns=(--set 'workloadPolicies.warnNamespaces={*-dev,infra-services}' --set 'workloadPolicies.enforcedNamespaces={prod}')

# 1. off by default
render "${ns[@]}" | grep -q 'mapcolonies.io/grafana-alerts' && fail "default render must not contain the alert ConfigMap"

# 2. on: ConfigMap with the sidecar label in the release namespace
out=$(render "${on[@]}" "${ns[@]}")
grep -q 'mapcolonies.io/grafana-alerts: "true"' <<<"$out" || fail "alert ConfigMap missing"
grep -q 'namespace: gatekeeper-system' <<<"$out" || fail "ConfigMap not in the release namespace"

# 3. scope: warn namespaces only, globs become regexes, enforced excluded by default
grep -qF 'resource_namespace=~\"(.*-dev|infra-services)\"' <<<"$out" || fail "namespace scope should be the warn list"
grep -q 'prod' <<<"$(grep -F 'resource_namespace' <<<"$out")" && fail "enforced namespaces must be excluded by default"

# 4. enforced switch adds enforced namespaces
out=$(render "${on[@]}" "${ns[@]}" --set deployAlerts.includeEnforcedNamespaces=true)
grep -qF 'resource_namespace=~\"(.*-dev|infra-services|prod)\"' <<<"$out" || fail "enforced namespaces not added by switch"

# 5. labels, datasource, workload rules only
out=$(render "${on[@]}" "${ns[@]}")
grep -q 'alert_team: infra' <<<"$out" || fail "alert_team=infra missing"
grep -q 'severity: warning' <<<"$out" || fail "severity=warning missing"
grep -q 'datasourceUid: loki' <<<"$out" || fail "loki datasource missing"
grep -qF 'constraint_name=~\"workload-.*\"' <<<"$out" || fail "must be limited to workload rules"
out=$(render "${on[@]}" "${ns[@]}" --set deployAlerts.defaultTeam=raster)
grep -q 'alert_team: raster' <<<"$out" || fail "defaultTeam not used"

# 6. annotations are plain text: no Slack links, bold or emoji codes
ann=$(render "${on[@]}" "${ns[@]}" | sed -n '/annotations:/,/^        [a-z]*:$/p')
[ -n "$ann" ] || fail "no annotations rendered"
grep -Eq '<https?://|\|[^|]*>|\*[A-Za-z]|:[a-z_]+:' <<<"$ann" && fail "annotations contain Slack formatting"
grep -q 'request_username' <<<"$ann" || fail "annotations must name the deploying user"
grep -q 'exempt' <<<"$ann" || fail "annotations must explain how to exempt"

# 7. fails loudly when nothing is in scope
err=$(render "${on[@]}" 2>&1 || true)
grep -q 'deployAlerts needs at least one namespace' <<<"$err" || fail "empty scope must fail"

echo "OK"
