#!/usr/bin/env bash
# Render assertions for alerts that must not send resolved messages: per-team contact
# points with disableResolveMessage, and a notification-policy route selecting them.
# Run from charts/grafana: tests/no-resolve-routing.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
render() {
  helm template t . --namespace infra --set grafana.alertingReceiverType=msteams \
    --set 'grafana.alertingTeamsWebhooks[0].team=infra' \
    --set 'grafana.alertingTeamsWebhooks[1].team=raster' "$@"
}
# section <file> <rendered>: the provisioning file inside the ConfigMap
section() { awk -v f="  $1: |" '$0==f{p=1;next} /^  [a-z-]+\.yaml: \|/{p=0} p' <<<"$2"; }

out=$(render)
cp=$(section contact-points.yaml "$out")
np=$(section notification-policy.yaml "$out")

# 1. every team gets a second contact point to the same webhook, without resolved messages
for t in infra raster; do
  T=$(tr a-z A-Z <<<"$t")
  grep -q "name: $t-alerts-no-resolve" <<<"$cp" || fail "$t: no-resolve contact point missing"
  [ "$(grep -c "url: \"\${${T}_WEBHOOK}\"" <<<"$cp")" = 2 ] || fail "$t: both contact points must use \${${T}_WEBHOOK}"
done
[ "$(grep -c 'disableResolveMessage: true' <<<"$cp")" = 2 ] || fail "expected exactly 2 contact points with disableResolveMessage: true"
[ "$(grep -c 'disableResolveMessage: false' <<<"$cp")" = 2 ] || fail "existing contact points must keep resolved messages"
[ "$(grep -c 'type: msteams' <<<"$cp")" = 4 ] || fail "all contact points must take their type from alertingReceiverType"
grep -qi slack <<<"$cp" && fail "contact points must not mention Slack"
grep -qi slack <<<"$np" && fail "policy must not mention Slack"
grep -q 'uid: raster-receiver-no-resolve' <<<"$cp" || fail "uid missing or not unique"

# 2. policy: inside each team route, the no-resolve route comes before the severity route
r=$(awk '/alert_team = "raster"/{p=1} p' <<<"$np")
no=$(grep -n 'notify_resolved = "false"' <<<"$r" | head -1 | cut -d: -f1)
sev=$(grep -n 'severity =~' <<<"$r" | head -1 | cut -d: -f1)
[ -n "$no" ] && [ -n "$sev" ] && [ "$no" -lt "$sev" ] || fail "no-resolve route must precede the severity route"
grep -q 'receiver: "raster-alerts-no-resolve"' <<<"$r" || fail "route must use the no-resolve contact point"
# each alert is its own notification (grouping would bundle several violations)
grep -qF "group_by: ['...']" <<<"$r" || fail "no-resolve route must not group alerts"
# the existing routing is unchanged
grep -q 'receiver: "raster-alerts"' <<<"$r" || fail "existing team receiver lost"
grep -q 'severity =~ "warning|info"' <<<"$r" || fail "existing severity route lost"
[ "$(grep -c 'receiver: infra-alerts' <<<"$np")" = 1 ] || fail "root receiver changed"

# 3. no teams: nothing rendered, as before
out=$(helm template t . --namespace infra)
grep -q 'no-resolve' <<<"$out" && fail "no teams: no contact points expected"

echo PASS
