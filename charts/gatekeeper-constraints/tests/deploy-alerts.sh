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
grep -q 'notify_resolved: "false"' <<<"$out" || fail "notify_resolved=false label missing (selects the no-resolve contact point)"
grep -q 'datasourceUid: loki' <<<"$out" || fail "loki datasource missing"
grep -qF 'constraint_name=~\"workload-.*\"' <<<"$out" || fail "must be limited to workload rules"
out=$(render "${on[@]}" "${ns[@]}" --set deployAlerts.defaultTeam=raster)
grep -q 'alert_team: raster' <<<"$out" || fail "defaultTeam not used"

# 5b. description drops the "denied admission: " prefix of Gatekeeper's log message (with or without a leading "Gatekeeper ") (warnings are admitted) and its
#     trailing exempt sentence (how_to_exempt says it), so the notification template stays generic
desc=$(grep -m1 'description:' <<<"$out")
grep -qF 'reReplaceAll \"^(Gatekeeper )?denied admission: \" \"\"' <<<"$desc" || fail "description must cut the denied-admission prefix"
grep -qF 'reReplaceAll \" To exempt this workload.*$\" \"\"' <<<"$desc" || fail "description must cut the trailing exempt sentence"

# 6. annotations are plain text: no Slack links, bold or emoji codes
ann=$(render "${on[@]}" "${ns[@]}" | sed -n '/annotations:/,/^        [a-z]*:$/p')
[ -n "$ann" ] || fail "no annotations rendered"
grep -Eq '<https?://|\|[^|]*>|\*[A-Za-z]|:[a-z_]+:' <<<"$ann" && fail "annotations contain Slack formatting"
grep -q 'request_username' <<<"$ann" || fail "annotations must name the deploying user"
grep -q 'exempt' <<<"$ann" || fail "annotations must explain how to exempt"

# 7. fails loudly when nothing is in scope
err=$(render "${on[@]}" 2>&1 || true)
grep -q 'deployAlerts needs at least one namespace' <<<"$err" || fail "empty scope must fail"

# 8. namespace -> team mapping: one rule per mapped namespace, per-team alert_team,
#    silenced namespaces get no rule, unmapped namespaces fall back to defaultTeam.
map=(--set 'namespaceTeams[0].namespace=raster-dev'  --set 'namespaceTeams[0].team=raster'
     --set 'namespaceTeams[1].namespace=dem-dev'     --set 'namespaceTeams[1].team=3d'
     --set 'namespaceTeams[2].namespace=gateway-dev' --set 'namespaceTeams[2].silence=true')
# block <team> <output>: the rule(s) labelled with that alert_team
block() { awk -v t="alert_team: $1" 'BEGIN{RS="- uid: "} index($0,t){print}' <<<"$2"; }
out=$(render "${on[@]}" "${ns[@]}" "${map[@]}")
[ "$(grep -c 'alert_team:' <<<"$out")" = 3 ] || fail "expected rules for raster, 3d and the infra fallback only"
r=$(block raster "$out"); [ -n "$r" ] || fail "raster rule missing"
grep -qF 'resource_namespace=~\"(raster-dev)\"' <<<"$r" || fail "raster rule must select raster-dev"
grep -q 'gateway-dev' <<<"$r" && fail "raster rule must not mention gateway-dev"
r=$(block 3d "$out"); [ -n "$r" ] || fail "3d rule missing"
grep -qF 'resource_namespace=~\"(dem-dev)\"' <<<"$r" || fail "3d rule must select dem-dev"
r=$(block infra "$out"); [ -n "$r" ] || fail "infra fallback rule missing"
grep -qF 'resource_namespace!~\"(raster-dev|dem-dev|gateway-dev)\"' <<<"$r" \
  || fail "fallback must exclude every mapped and silenced namespace"
# a silenced namespace alone: no rule for it, excluded from the fallback
out=$(render "${on[@]}" "${ns[@]}" --set 'namespaceTeams[0].namespace=gateway-dev' --set 'namespaceTeams[0].silence=true')
[ "$(grep -c 'alert_team:' <<<"$out")" = 1 ] || fail "silenced namespace must not get its own rule"
grep -qF 'resource_namespace!~\"(gateway-dev)\"' <<<"$out" || fail "silenced namespace must be excluded from fallback"
# defaultTeam is the fallback team
out=$(render "${on[@]}" "${ns[@]}" "${map[@]}" --set deployAlerts.defaultTeam=devops)
[ -n "$(block devops "$out")" ] || fail "fallback must use defaultTeam"
# rule uids and titles are unique
out=$(render "${on[@]}" "${ns[@]}" "${map[@]}")
[ "$(grep -E '^ +(- uid|title): ' <<<"$out" | sort | uniq -d | wc -l)" = 0 ] || fail "rule uid/title must be unique"

# 9. exact namespaces win over globs, whatever the list order
out=$(render "${on[@]}" "${ns[@]}" --set 'namespaceTeams[0].namespace=*-dev' --set 'namespaceTeams[0].team=app' \
  --set 'namespaceTeams[1].namespace=raster-dev' --set 'namespaceTeams[1].team=raster')
r=$(block raster "$out"); grep -q 'resource_namespace!~' <<<"$r" && fail "exact mapping must not be excluded by a glob"
r=$(block app "$out"); grep -qF 'resource_namespace!~\"(raster-dev)\"' <<<"$r" || fail "glob mapping must exclude the exact namespace"
# among globs, the first listed wins
out=$(render "${on[@]}" "${ns[@]}" --set 'namespaceTeams[0].namespace=r*' --set 'namespaceTeams[0].team=raster' \
  --set 'namespaceTeams[1].namespace=*-dev' --set 'namespaceTeams[1].team=app')
r=$(block app "$out"); grep -qF 'resource_namespace!~\"(r.*)\"' <<<"$r" || fail "later glob must exclude earlier glob"

# 10. mapping without alerts enabled renders nothing; bad entries fail loudly
render "${ns[@]}" "${map[@]}" | grep -q 'mapcolonies.io/grafana-alerts' && fail "mapping alone must not render alerts"
err=$(render "${on[@]}" "${ns[@]}" --set 'namespaceTeams[0].namespace=x-dev' 2>&1 || true)
grep -q 'namespaceTeams\[0\]: set either team or silence' <<<"$err" || fail "entry without team or silence must fail"
err=$(render "${on[@]}" "${ns[@]}" --set 'namespaceTeams[0].namespace=x-dev' --set 'namespaceTeams[0].team=a' --set 'namespaceTeams[0].silence=true' 2>&1 || true)
grep -q 'namespaceTeams\[0\]: set either team or silence' <<<"$err" || fail "entry with team and silence must fail"
err=$(render "${on[@]}" "${ns[@]}" --set 'namespaceTeams[0].namespace=X dev' --set 'namespaceTeams[0].team=a' 2>&1 || true)
grep -q 'namespaceTeams\[0\].namespace' <<<"$err" || fail "bad namespace must fail"
err=$(render "${on[@]}" "${ns[@]}" --set 'namespaceTeams[0].namespace=x-dev' --set 'namespaceTeams[0].team=Bad Team' 2>&1 || true)
grep -q 'namespaceTeams\[0\].team' <<<"$err" || fail "bad team must fail"

echo "OK"
