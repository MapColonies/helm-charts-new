#!/usr/bin/env bash
# Render assertions for the sidecar Roles: each Role grants configmaps and/or secrets according
# to sidecar.<kind>.resource of the sidecars that watch its namespace.
# Run from charts/grafana: tests/sidecar-rbac.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
render() {
  helm template t . --namespace infra-dev --show-only templates/sidecar-rbac.yaml \
    --set 'grafana.sidecar.alerts.searchNamespace={infra-dev,gatekeeper-system}' "$@"
}
# render_ns <values file> [args]: like render, with searchNamespace from the file (--set would win)
render_ns() { helm template t . --namespace infra-dev --show-only templates/sidecar-rbac.yaml -f "$@"; }
# role <rendered> <namespace>: the resources list of the Role in that namespace
role() { awk -v ns="$2" '/^kind:/{k=$2} k=="Role"&&$1=="namespace:"{n=$2} k=="Role"&&n==ns&&$1=="resources:"{sub(/^ *resources: /,"");print}' <<<"$1"; }

# 1. both (upstream default): configmaps and secrets everywhere, as before.
out=$(render)
[ "$(role "$out" gatekeeper-system)" = '["configmaps", "secrets"]' ] || fail "both: gatekeeper-system: $(role "$out" gatekeeper-system)"
[ "$(role "$out" infra-dev)" = '["configmaps", "secrets"]' ] || fail "both: infra-dev: $(role "$out" infra-dev)"
[ "$(grep -c '^kind: RoleBinding' <<<"$out")" = 2 ] || fail "both: expected one RoleBinding per namespace"

# 2. configmap: no secrets where only the alerts sidecar looks. The dashboards and datasources
#    sidecars (default both, no searchNamespace) watch the release namespace, which keeps secrets.
out=$(render --set grafana.sidecar.alerts.resource=configmap)
[ "$(role "$out" gatekeeper-system)" = '["configmaps"]' ] || fail "configmap: gatekeeper-system: $(role "$out" gatekeeper-system)"
[ "$(role "$out" infra-dev)" = '["configmaps", "secrets"]' ] || fail "configmap: infra-dev must keep secrets for dashboards/datasources"
out=$(render --set grafana.sidecar.alerts.resource=configmap \
  --set grafana.sidecar.dashboards.resource=configmap --set grafana.sidecar.datasources.resource=configmap)
grep -q secrets <<<"$out" && fail "configmap everywhere: no Role may list secrets"
out=$(render --set grafana.sidecar.alerts.resource=configmap --set grafana.sidecar.dashboards.enabled=false \
  --set grafana.sidecar.datasources.enabled=false)
grep -q secrets <<<"$out" && fail "disabled sidecars must not add secrets"

# 3. secret: secrets only where only the alerts sidecar looks.
out=$(render --set grafana.sidecar.alerts.resource=secret)
[ "$(role "$out" gatekeeper-system)" = '["secrets"]' ] || fail "secret: gatekeeper-system: $(role "$out" gatekeeper-system)"
[ "$(role "$out" infra-dev)" = '["configmaps", "secrets"]' ] || fail "secret: infra-dev: $(role "$out" infra-dev)"

# 4. Roles are created only for the alerts sidecar's namespaces, as before; another sidecar that
#    watches one of them adds its resource there.
out=$(render --set grafana.sidecar.alerts.resource=configmap \
  --set 'grafana.sidecar.dashboards.searchNamespace={gatekeeper-system,raster-dev}' \
  --set grafana.sidecar.dashboards.resource=secret)
[ "$(grep -c '^kind: Role$' <<<"$out")" = 2 ] || fail "expected Roles in infra-dev and gatekeeper-system only"
[ "$(role "$out" gatekeeper-system)" = '["configmaps", "secrets"]' ] || fail "shared namespace must combine resources"
[ "$(role "$out" infra-dev)" = '["configmaps", "secrets"]' ] || fail "infra-dev: datasources (both) still watches it"
out=$(render --set grafana.sidecar.alerts.resource=configmap --set grafana.sidecar.dashboards.resource=configmap \
  --set grafana.sidecar.datasources.resource=configmap --set grafana.sidecar.notifiers.enabled=true)
[ "$(role "$out" infra-dev)" = '["configmaps", "secrets"]' ] || fail "notifiers (both) watches infra-dev: it needs secrets"
[ "$(role "$out" gatekeeper-system)" = '["configmaps"]' ] || fail "notifiers does not watch gatekeeper-system"

# 5. searchNamespace is read like the subchart reads it: tpl and comma-separated strings.
out=$(render_ns <(printf '%s\n' 'grafana:' '  sidecar:' '    alerts:' '      resource: configmap' \
  '      searchNamespace: ["{{ .Release.Namespace }}", gatekeeper-system]'))
[ "$(role "$out" infra-dev)" = '["configmaps", "secrets"]' ] || fail "tpl namespace: infra-dev Role missing"
[ "$(role "$out" gatekeeper-system)" = '["configmaps"]' ] || fail "tpl namespace: gatekeeper-system Role missing"
# .Values in the template is the subchart's (grafana.*), as for the sidecar's NAMESPACE.
out=$(render_ns <(printf '%s\n' 'grafana:' '  sidecar:' '    alerts:' \
  '      resource: configmap' '      searchNamespace: ["{{ .Release.Namespace }}", "{{ .Values.alertsNs }}"]') --set grafana.alertsNs=gatekeeper-system)
[ "$(role "$out" gatekeeper-system)" = '["configmaps"]' ] || fail "tpl .Values must resolve like in the subchart"
out=$(render --set grafana.sidecar.alerts.resource=configmap \
  --set 'grafana.sidecar.alerts.searchNamespace=infra-dev\,gatekeeper-system')
[ "$(grep -c '^kind: Role$' <<<"$out")" = 2 ] || fail "comma-separated string must give one Role per namespace"
[ "$(role "$out" gatekeeper-system)" = '["configmaps"]' ] || fail "comma-separated: gatekeeper-system"

# 6. ALL: no namespaced Role for it (cluster-wide RBAC comes from elsewhere); nothing fails.
out=$(helm template t . --namespace infra-dev --set 'grafana.sidecar.alerts.searchNamespace=ALL')
grep -q 'name: grafana-reader' <<<"$out" && fail "ALL must not render a Role"
out=$(render --set grafana.sidecar.alerts.resource=configmap --set 'grafana.sidecar.dashboards.searchNamespace=ALL' \
  --set grafana.sidecar.datasources.resource=configmap)
[ "$(role "$out" infra-dev)" = '["configmaps"]' ] || fail "dashboards ALL must not add to namespaced Roles"

# 7. Invalid resource fails the render.
err=$(render --set grafana.sidecar.alerts.resource=secrets 2>&1 || true)
grep -q 'sidecar.alerts.resource: must be configmap, secret or both' <<<"$err" || fail "bad resource must fail"

# 8. No searchNamespace anywhere: no Role.
out=$(helm template t . --namespace infra-dev)
grep -q 'name: grafana-reader' <<<"$out" && fail "no searchNamespace: no Role expected"

echo PASS
