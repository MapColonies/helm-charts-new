#!/usr/bin/env bash
# Render assertions for the readable no-resolve notifications: the notification template is
# provisioned, and only the <team>-alerts-no-resolve contact points use it.
# Run from charts/grafana: tests/notification-templates.sh
set -euo pipefail
cd "$(dirname "$0")/.."

render() { helm template t . --namespace infra --set 'grafana.alertingTeamsWebhooks[0].team=infra' "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
# contact point <name>'s block in the rendered contact-points.yaml
cp_block() { awk -v n="name: $1\$" '$0 ~ n {f=1; next} f && /^ +- orgId:/ {f=0} f' <<<"$2"; }

# 1. The template file is provisioned with Grafana's braces untouched (not run through Helm tpl).
out=$(render --set grafana.alertingReceiverType=slack)
grep -q 'notification-templates.yaml: |' <<<"$out" || fail "notification-templates.yaml missing from the provisioning ConfigMap"
grep -qF '{{ define "no_resolve_notification.title" -}}' <<<"$out" || fail "title template not rendered verbatim"
grep -qF '{{ define "no_resolve_notification.message" -}}' <<<"$out" || fail "message template not rendered verbatim"

# 1a. The template stays generic (rule wording is cleaned in the rule) and keeps the silence link.
tpl=$(sed -n '/no_resolve_notification.message/,$p' files/notification-templates.yaml)
grep -qF 'SilenceURL' <<<"$tpl" || fail "message must keep the Silence link"
sed '/^ *#/d' files/notification-templates.yaml | grep -qi 'gatekeeper' && fail "template must not mention Gatekeeper wording; clean it in the rule"

# 1b. No teams: nothing is provisioned, as before.
none=$(helm template t . --namespace infra)
grep -q 'notification-templates.yaml' <<<"$none" && fail "no teams: notification template must not be provisioned"

# 2. Slack: only the no-resolve contact point gets title and text.
nr=$(cp_block infra-alerts-no-resolve "$out")
grep -qF 'title: "{{ template \"no_resolve_notification.title\" . }}"' <<<"$nr" || fail "slack no-resolve: title missing"
grep -qF 'text: "{{ template \"no_resolve_notification.message\" . }}"' <<<"$nr" || fail "slack no-resolve: text missing"
plain=$(cp_block infra-alerts "$out")
grep -qE '^ +(title|text|message):' <<<"$plain" && fail "the regular contact point must keep Grafana's default message"

# 3. Teams uses message instead of text.
out=$(render --set grafana.alertingReceiverType=teams)
nr=$(cp_block infra-alerts-no-resolve "$out")
grep -qF 'message: "{{ template \"no_resolve_notification.message\" . }}"' <<<"$nr" || fail "teams no-resolve: message missing"
grep -qE '^ +text:' <<<"$nr" && fail "teams no-resolve: must not set text"

# 4. Any other receiver type is left alone.
out=$(render --set grafana.alertingReceiverType=webhook)
nr=$(cp_block infra-alerts-no-resolve "$out")
grep -qE '^ +(title|text|message):' <<<"$nr" && fail "unknown receiver type must not get message settings"

echo "PASS"
