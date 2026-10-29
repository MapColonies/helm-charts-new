#!/usr/bin/env bash
# Render assertions for the readable no-resolve and digest notifications: the notification
# templates are provisioned, and only the <team>-alerts-no-resolve / <team>-alerts-digest
# contact points use them.
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

grep -qF '{{ define "digest_notification.title" -}}' <<<"$out" || fail "digest title template not rendered verbatim"
grep -qF '{{ define "digest_notification.message" -}}' <<<"$out" || fail "digest message template not rendered verbatim"

# 1c. Digest: title and lines from the digest_* annotations (with fallbacks), at most 25
#     lines with a "showing the first 25 of N" note, footer once, one Silence link.
dg=$(sed -n '/digest_notification.title/,$p' files/notification-templates.yaml)
grep -qF 'or .Annotations.digest_title .Labels.alertname' <<<"$dg" || fail "digest title must come from digest_title, else alertname"
grep -qF '{{ end }} ({{ len $alerts }})' <<<"$dg" || fail "digest title must show the alert count"
grep -qF 'or $a.Annotations.digest_line $a.Annotations.summary' <<<"$dg" || fail "digest lines must come from digest_line, else summary"
grep -qF 'if lt $i 25' <<<"$dg" || fail "digest must cap the lines at 25"
grep -qF 'showing the first 25 of {{ len $alerts }}' <<<"$dg" || fail "digest must say how many alerts the cap hides"
grep -qF 'with index $alerts 0 }}{{ with .Annotations.digest_footer' <<<"$dg" || fail "digest footer must come once, from the first alert"
[ "$(grep -c 'Silence:' <<<"$dg")" = 1 ] || fail "digest must have exactly one Silence link"
# the per-alert layout does not print the digest_* annotations
grep -qF '(not (match "^digest_" .Name))' files/notification-templates.yaml || fail "no-resolve message must skip digest_* annotations"

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
dg=$(cp_block infra-alerts-digest "$out")
grep -qF 'title: "{{ template \"digest_notification.title\" . }}"' <<<"$dg" || fail "slack digest: title missing"
grep -qF 'text: "{{ template \"digest_notification.message\" . }}"' <<<"$dg" || fail "slack digest: text missing"
plain=$(cp_block infra-alerts "$out")
grep -qE '^ +(title|text|message):' <<<"$plain" && fail "the regular contact point must keep Grafana's default message"

# 3. Teams uses message instead of text.
out=$(render --set grafana.alertingReceiverType=teams)
nr=$(cp_block infra-alerts-no-resolve "$out")
grep -qF 'message: "{{ template \"no_resolve_notification.message\" . }}"' <<<"$nr" || fail "teams no-resolve: message missing"
grep -qE '^ +text:' <<<"$nr" && fail "teams no-resolve: must not set text"
dg=$(cp_block infra-alerts-digest "$out")
grep -qF 'message: "{{ template \"digest_notification.message\" . }}"' <<<"$dg" || fail "teams digest: message missing"
grep -qE '^ +text:' <<<"$dg" && fail "teams digest: must not set text"

# 4. Any other receiver type is left alone.
out=$(render --set grafana.alertingReceiverType=webhook)
nr=$(cp_block infra-alerts-no-resolve "$out")
grep -qE '^ +(title|text|message):' <<<"$nr" && fail "unknown receiver type must not get message settings"
dg=$(cp_block infra-alerts-digest "$out")
grep -qE '^ +(title|text|message):' <<<"$dg" && fail "unknown receiver type must not get digest settings"

echo "PASS"
