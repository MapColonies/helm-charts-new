#!/usr/bin/env bash
# Render assertions for team webhooks: chart-created Secret vs external Secret.
# Run from charts/grafana: tests/webhooks-secret.sh
set -euo pipefail
cd "$(dirname "$0")/.."

render() { helm template t . --namespace infra "$@"; }
secret_count() { grep -c '^  name: grafana-webhooks$' <<<"$1" || true; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Inline url (existing installs): chart still creates the grafana-webhooks Secret.
out=$(render --set grafana.alertingReceiverType=slack \
  --set 'grafana.alertingTeamsWebhooks[0].team=infra' \
  --set 'grafana.alertingTeamsWebhooks[0].url=https://example.invalid/hook')
[ "$(secret_count "$out")" = 1 ] || fail "inline url: expected chart-created Secret"
grep -q 'INFRA_WEBHOOK: "https://example.invalid/hook"' <<<"$out" || fail "inline url: key missing"

# 2. Teams without url (webhooks come from an external Secret): chart must not create
#    a Secret, so the external Secret (grafana-webhooks-external) does not collide.
out=$(render --set grafana.alertingReceiverType=slack \
  --set 'grafana.alertingTeamsWebhooks[0].team=infra')
[ "$(secret_count "$out")" = 0 ] || fail "no url: chart must not create a Secret"
grep -q 'INFRA_WEBHOOK' <<<"$out" || fail "no url: contact point must still reference \${INFRA_WEBHOOK}"

# 3. No teams at all: no Secret either.
out=$(render)
[ "$(secret_count "$out")" = 0 ] || fail "no teams: chart must not create a Secret"

# 4. Both Secrets are optional envFrom entries by default; a custom name replaces the list.
out=$(render --set grafana.alertingReceiverType=slack --set 'grafana.alertingTeamsWebhooks[0].team=infra')
grep -q 'name: grafana-webhooks-external' <<<"$out" || fail "default envFrom must include grafana-webhooks-external"
grep -q 'name: "\?grafana-webhooks"\?$' <<<"$out" || fail "default envFrom must keep grafana-webhooks"
[ "$(grep -c 'optional: true' <<<"$out")" -ge 2 ] || fail "both envFrom Secrets must be optional"

out=$(render --set grafana.alertingReceiverType=slack \
  --set 'grafana.alertingTeamsWebhooks[0].team=infra' \
  --set 'grafana.envFromSecrets[0].name=my-webhooks')
grep -q 'name: my-webhooks' <<<"$out" || fail "custom secret name not in envFrom"

# 5. Team names that would give an invalid env var name: a leading digit gets a TEAM_ prefix
#    (the same key in the contact points and the inline Secret); other teams keep <TEAM>_WEBHOOK.
out=$(render --set grafana.alertingReceiverType=slack \
  --set 'grafana.alertingTeamsWebhooks[0].team=3d' \
  --set 'grafana.alertingTeamsWebhooks[0].url=https://example.invalid/3d' \
  --set 'grafana.alertingTeamsWebhooks[1].team=my-team')
grep -qF 'url: "${TEAM_3D_WEBHOOK}"' <<<"$out" || fail "3d: contact point must use \${TEAM_3D_WEBHOOK}"
grep -q 'TEAM_3D_WEBHOOK: "https://example.invalid/3d"' <<<"$out" || fail "3d: Secret key must be TEAM_3D_WEBHOOK"
grep -qF '${3D_WEBHOOK}' <<<"$out" && fail "3d: invalid env var name rendered"
grep -qF 'url: "${MY_TEAM_WEBHOOK}"' <<<"$out" || fail "my-team: hyphen must become underscore"

# 6. A team name that cannot map to an env var fails loudly.
err=$(render --set grafana.alertingReceiverType=slack --set 'grafana.alertingTeamsWebhooks[0].team=Bad Team' 2>&1 || true)
grep -q 'team "Bad Team" must only contain' <<<"$err" || fail "bad team name must fail"

echo "PASS"
