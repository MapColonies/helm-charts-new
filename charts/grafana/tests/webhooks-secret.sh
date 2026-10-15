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
#    a Secret, so an external Secret with any name (incl. grafana-webhooks) does not collide.
out=$(render --set grafana.alertingReceiverType=slack \
  --set 'grafana.alertingTeamsWebhooks[0].team=infra')
[ "$(secret_count "$out")" = 0 ] || fail "no url: chart must not create a Secret"
grep -q 'INFRA_WEBHOOK' <<<"$out" || fail "no url: contact point must still reference \${INFRA_WEBHOOK}"

# 3. No teams at all: no Secret either.
out=$(render)
[ "$(secret_count "$out")" = 0 ] || fail "no teams: chart must not create a Secret"

# 4. Custom external Secret name is wired into the pod env.
out=$(render --set grafana.alertingReceiverType=slack \
  --set 'grafana.alertingTeamsWebhooks[0].team=infra' \
  --set 'grafana.envFromSecrets[0].name=my-webhooks')
grep -q 'name: my-webhooks' <<<"$out" || fail "custom secret name not in envFrom"

echo "PASS"
