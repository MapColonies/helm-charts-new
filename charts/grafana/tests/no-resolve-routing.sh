#!/usr/bin/env bash
# Render assertions for alerts that must not send resolved messages: per-team contact
# points with disableResolveMessage (one per alert and one digest per alert_group), and the
# notification-policy routes selecting them.
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

# 1. every team gets a no-resolve and a digest contact point to the same webhook, without
#    resolved messages
# cp_block <name>: that contact point's block
cp_block() { awk -v n="name: $1\$" '$0 ~ n {f=1; next} f && /^ +- orgId:/ {f=0} f' <<<"$cp"; }
for t in infra raster; do
  T=$(tr a-z A-Z <<<"$t")
  grep -q "name: $t-alerts-no-resolve" <<<"$cp" || fail "$t: no-resolve contact point missing"
  grep -q "name: $t-alerts-digest\$" <<<"$cp" || fail "$t: digest contact point missing"
  [ "$(grep -c "url: \"\${${T}_WEBHOOK}\"" <<<"$cp")" = 3 ] || fail "$t: all three contact points must use \${${T}_WEBHOOK}"
  d=$(cp_block "$t-alerts-digest")
  grep -q "uid: $t-receiver-digest\$" <<<"$d" || fail "$t: digest receiver uid missing or not unique"
  grep -q 'disableResolveMessage: true' <<<"$d" || fail "$t: digest contact point must not send resolved messages"
done
[ "$(grep -c 'disableResolveMessage: true' <<<"$cp")" = 4 ] || fail "expected exactly 4 contact points with disableResolveMessage: true"
[ "$(grep -c 'disableResolveMessage: false' <<<"$cp")" = 2 ] || fail "existing contact points must keep resolved messages"
[ "$(grep -c 'type: msteams' <<<"$cp")" = 6 ] || fail "all contact points must take their type from alertingReceiverType"
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
# 2b. alerts with an alert_group label: one digest per team and group, routed before the
#     generic no-resolve route (Grafana takes the first matching child route)
for t in infra raster; do
  r=$(awk -v m="alert_team = \"$t\"" 'index($0,m){p=1;next} p && /alert_team = /{p=0} p' <<<"$np")
  dg=$(grep -n "receiver: \"$t-alerts-digest\"" <<<"$r" | head -1 | cut -d: -f1 || true)
  nr=$(grep -n "receiver: \"$t-alerts-no-resolve\"" <<<"$r" | head -1 | cut -d: -f1 || true)
  [ -n "$dg" ] || fail "$t: digest route missing"
  [ -n "$nr" ] && [ "$dg" -lt "$nr" ] || fail "$t: digest route must precede the no-resolve route"
  # the first child route of the team route must be the digest route
  blk=$(awk '/- matchers:/{n++} n==1' <<<"$r")
  grep -q "receiver: \"$t-alerts-digest\"" <<<"$blk" || fail "$t: digest route must be the first child route"
  grep -qF 'alert_group =~ ".+"' <<<"$blk" || fail "$t: digest route must require alert_group"
  grep -qF 'notify_resolved = "false"' <<<"$blk" || fail "$t: digest route must require notify_resolved=false"
  grep -qF 'group_by: [alert_team, alert_group]' <<<"$blk" || fail "$t: digest route must group by [alert_team, alert_group]"
  for kv in 'group_wait: 1m' 'group_interval: 5m' 'repeat_interval: 12h'; do
    grep -qF "$kv" <<<"$blk" || fail "$t: digest route needs $kv"
  done
done
# the existing routing is unchanged
grep -q 'receiver: "raster-alerts"' <<<"$r" || fail "existing team receiver lost"
grep -q 'severity =~ "warning|info"' <<<"$r" || fail "existing severity route lost"
[ "$(grep -c 'receiver: infra-alerts' <<<"$np")" = 1 ] || fail "root receiver changed"

# 3. no teams: nothing rendered, as before
out=$(helm template t . --namespace infra)
grep -q 'no-resolve' <<<"$out" && fail "no teams: no contact points expected"

echo PASS
