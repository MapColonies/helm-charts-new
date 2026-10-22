#!/usr/bin/env bash
# Render assertions for team webhooks: chart-created Secret vs external Secret, and the
# per-team secretKeyRef env vars that read them.
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

# 4. Each team's env var is read with secretKeyRef (optional: false), so a missing key blocks the
#    new pod instead of starting Grafana with an empty URL: inline url -> grafana-webhooks,
#    no url -> alertingWebhooksSecret (default grafana-webhooks-external). No envFrom is left.
# env_ref <rendered> <ENV>: "<secret>/<key>/<optional>" of that env var in the grafana Deployment
env_ref() {
  sed -n '/^kind: Deployment/,/^---/p' <<<"$1" | grep -A6 "^ *- name: \"$2\"$" |
    awk '$1=="secretKeyRef:"{r=1} r&&$1=="key:"{k=$2} r&&$1=="name:"{n=$2} r&&$1=="optional:"{o=$2} $1=="-"{if(r)exit} END{print n"/"k"/"o}'
}
out=$(render --set grafana.alertingReceiverType=slack \
  --set 'grafana.alertingTeamsWebhooks[0].team=infra' \
  --set 'grafana.alertingTeamsWebhooks[1].team=raster' \
  --set 'grafana.alertingTeamsWebhooks[1].url=https://example.invalid/raster')
[ "$(env_ref "$out" INFRA_WEBHOOK)" = grafana-webhooks-external/INFRA_WEBHOOK/false ] ||
  fail "no url: INFRA_WEBHOOK must use secretKeyRef grafana-webhooks-external, got $(env_ref "$out" INFRA_WEBHOOK)"
[ "$(env_ref "$out" RASTER_WEBHOOK)" = grafana-webhooks/RASTER_WEBHOOK/false ] ||
  fail "inline url: RASTER_WEBHOOK must use secretKeyRef grafana-webhooks, got $(env_ref "$out" RASTER_WEBHOOK)"
grep -q 'envFrom:' <<<"$out" && fail "webhooks must not be loaded with envFrom any more"

# A custom alertingWebhooksSecret is used for teams without url only.
out=$(render --set grafana.alertingReceiverType=slack --set grafana.alertingWebhooksSecret=my-webhooks \
  --set 'grafana.alertingTeamsWebhooks[0].team=infra' \
  --set 'grafana.alertingTeamsWebhooks[1].team=raster' \
  --set 'grafana.alertingTeamsWebhooks[1].url=https://example.invalid/raster')
[ "$(env_ref "$out" INFRA_WEBHOOK)" = my-webhooks/INFRA_WEBHOOK/false ] || fail "custom secret name not used"
[ "$(env_ref "$out" RASTER_WEBHOOK)" = grafana-webhooks/RASTER_WEBHOOK/false ] || fail "inline url must keep grafana-webhooks"

# Without a Secret name, a team without url fails the render.
err=$(render --set grafana.alertingReceiverType=slack --set grafana.alertingWebhooksSecret= \
  --set 'grafana.alertingTeamsWebhooks[0].team=infra' 2>&1 || true)
grep -q 'alertingWebhooksSecret: required for team "infra"' <<<"$err" || fail "empty secret name must fail"

# An explicit envValueFrom entry for the same name wins, and is rendered once.
out=$(render --set grafana.alertingReceiverType=slack \
  --set 'grafana.alertingTeamsWebhooks[0].team=infra' \
  --set 'grafana.envValueFrom.INFRA_WEBHOOK.secretKeyRef.name=other' \
  --set 'grafana.envValueFrom.INFRA_WEBHOOK.secretKeyRef.key=hook')
[ "$(env_ref "$out" INFRA_WEBHOOK)" = other/hook/ ] || fail "explicit envValueFrom must win"
[ "$(grep -c 'name: "INFRA_WEBHOOK"' <<<"$out")" = 1 ] || fail "INFRA_WEBHOOK rendered more than once"

# No teams: no webhook env vars.
grep -q '_WEBHOOK' <<<"$(render)" && fail "no teams: no webhook env var expected"

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
[ "$(env_ref "$out" TEAM_3D_WEBHOOK)" = grafana-webhooks/TEAM_3D_WEBHOOK/false ] || fail "3d: env var must read key TEAM_3D_WEBHOOK"
[ "$(env_ref "$out" MY_TEAM_WEBHOOK)" = grafana-webhooks-external/MY_TEAM_WEBHOOK/false ] || fail "my-team: env var must read key MY_TEAM_WEBHOOK"

# 6. A team name that cannot map to an env var fails loudly.
err=$(render --set grafana.alertingReceiverType=slack --set 'grafana.alertingTeamsWebhooks[0].team=Bad Team' 2>&1 || true)
grep -q 'team "Bad Team" must only contain' <<<"$err" || fail "bad team name must fail"

# 7. If the subchart stops calling the hook (upstream change), the render fails instead of
#    leaving every contact point without a URL. Simulated on a copy without the hook call.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp -r . "$tmp/grafana"
sed -i '/include "grafana.webhookEnvValueFrom"/d' "$tmp/grafana/templates/_helpers.tpl"
err=$(helm template t "$tmp/grafana" --namespace infra --set grafana.alertingReceiverType=slack \
  --set 'grafana.alertingTeamsWebhooks[0].team=infra' 2>&1 || true)
grep -q 'env var INFRA_WEBHOOK for team "infra" was not rendered' <<<"$err" || fail "missing hook must fail the render"

echo "PASS"
