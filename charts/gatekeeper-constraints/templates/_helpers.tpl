{{/*
Validates workloadPolicies.exemptions and returns <rule>'s entries as a YAML list.
  {{- $exemptions := include "gatekeeper-constraints.workloadExemptions" (dict "root" . "rule" "cpuRatio") | fromYamlArray }}
*/}}
{{- define "gatekeeper-constraints.workloadExemptions" -}}
{{- $entries := list -}}
{{- range $i, $entry := .root.Values.workloadPolicies.exemptions -}}
{{- $where := printf "workloadPolicies.exemptions[%d]" $i -}}
{{- if not (kindIs "map" $entry) -}}
{{- fail (printf "%s: must be a map with namespace, kind, name, rules and reason" $where) -}}
{{- end -}}
{{- range $field := list "namespace" "kind" "name" "reason" -}}
{{- if not (toString (index $entry $field | default "") | trim) -}}
{{- fail (printf "%s: %s is required" $where $field) -}}
{{- end -}}
{{- end -}}
{{- if not (has $entry.kind (list "Deployment" "StatefulSet")) -}}
{{- fail (printf "%s: kind must be Deployment or StatefulSet, got %q" $where $entry.kind) -}}
{{- end -}}
{{- if or (not $entry.rules) (not (kindIs "slice" $entry.rules)) -}}
{{- fail (printf "%s: rules must be a list of cpuRatio, mclabels or both" $where) -}}
{{- end -}}
{{- range $rule := $entry.rules -}}
{{- if not (has $rule (list "cpuRatio" "mclabels")) -}}
{{- fail (printf "%s: unknown rule %q, expected cpuRatio or mclabels" $where $rule) -}}
{{- end -}}
{{- end -}}
{{- if has $.rule $entry.rules -}}
{{- $entries = append $entries (pick $entry "namespace" "kind" "name" "reason") -}}
{{- end -}}
{{- end -}}
{{- toYaml $entries -}}
{{- end -}}

{{/*
Returns <rule>'s enforcementAction for enforced namespaces: deny, warn or dryrun.
  {{- $action := include "gatekeeper-constraints.enforcementAction" (dict "root" . "rule" "cpuRatio") }}
*/}}
{{- define "gatekeeper-constraints.enforcementAction" -}}
{{- $action := index .root.Values.workloadPolicies .rule "enforcementAction" -}}
{{- if not (has $action (list "deny" "warn" "dryrun")) -}}
{{- fail (printf "workloadPolicies.%s.enforcementAction must be deny, warn or dryrun, got %q" .rule $action) -}}
{{- end -}}
{{- $action -}}
{{- end -}}

{{/* Namespace glob (* and ?) as a Loki regex. */}}
{{- define "gatekeeper-constraints.nsRegex" -}}
{{- if not (regexMatch "^[a-z0-9*?-]+$" (toString .)) }}
{{- fail (printf "namespace %q must only contain a-z, 0-9, -, * and ?" (toString .)) }}
{{- end }}
{{- . | replace "*" ".*" | replace "?" "." -}}
{{- end }}

{{/*
Env var (and Secret key) holding a team's webhook URL: <TEAM>_WEBHOOK, team upper-cased with
"-" as "_". A team starting with a digit gets a TEAM_ prefix (3d -> TEAM_3D_WEBHOOK), because
env var names cannot start with a digit. Same rule as grafana.webhookEnv in the grafana chart,
so both read the same Secret keys.
  {{ include "gatekeeper-constraints.webhookEnv" .team }}
*/}}
{{- define "gatekeeper-constraints.webhookEnv" -}}
{{- if not (regexMatch "^[a-z0-9_-]+$" (toString .)) -}}
{{- fail (printf "team %q must only contain a-z, 0-9, - and _" (toString .)) -}}
{{- end -}}
{{- $name := upper (toString .) | replace "-" "_" -}}
{{- if regexMatch "^[0-9]" $name -}}{{ $name = printf "TEAM_%s" $name }}{{- end -}}
{{- printf "%s_WEBHOOK" $name -}}
{{- end }}

{{/*
Validates dailyReport (call only when it is enabled). Renders nothing.
  {{- include "gatekeeper-constraints.dailyReportValidate" . }}
*/}}
{{- define "gatekeeper-constraints.dailyReportValidate" -}}
{{- $r := .Values.dailyReport -}}
{{- range $field := list "namespace" "schedule" "dashboardUrl" "environment" "webhooksSecret" -}}
{{- if not (toString (index $r $field | default "") | trim) -}}
{{- fail (printf "dailyReport.enabled needs dailyReport.%s" $field) -}}
{{- end -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" $r.namespace) -}}
{{- fail (printf "dailyReport.namespace %q is not a namespace name" $r.namespace) -}}
{{- end -}}
{{- if not (toString $r.loki.pushUrl | trim) -}}
{{- fail "dailyReport.enabled needs dailyReport.loki.pushUrl (the dashboard and the daily-report alerts read the run from Loki)" -}}
{{- end -}}
{{- range $field, $url := dict "dashboardUrl" $r.dashboardUrl "readmeUrl" $r.readmeUrl "loki.pushUrl" $r.loki.pushUrl "gator.url" $r.gator.url -}}
{{- if not (regexMatch "^https?://[^\\s|<>]+$" (toString $url)) -}}
{{- fail (printf "dailyReport.%s must be an http(s) URL, got %q" $field (toString $url)) -}}
{{- end -}}
{{- end -}}
{{- if eq $r.environment "undefined" -}}
{{- fail "dailyReport.environment must not be \"undefined\" (the Pod label rules reject it)" -}}
{{- end -}}
{{- if not (regexMatch "^[0-9a-f]{64}$" (toString $r.gator.sha256)) -}}
{{- fail (printf "dailyReport.gator.sha256 must be 64 lowercase hex characters, got %q" (toString $r.gator.sha256)) -}}
{{- end -}}
{{- if not (contains $r.gator.version $r.gator.url) -}}
{{- fail (printf "dailyReport.gator.url must contain the version %s" $r.gator.version) -}}
{{- end -}}
{{- if or (not $r.constraintKinds) (not (kindIs "slice" $r.constraintKinds)) -}}
{{- fail "dailyReport.constraintKinds must be a non-empty list of Constraint kinds" -}}
{{- end -}}
{{- range $r.constraintKinds -}}
{{- if not (regexMatch "^[A-Z][A-Za-z0-9]*$" (toString .)) -}}
{{- fail (printf "dailyReport.constraintKinds: %q is not a Constraint kind" (toString .)) -}}
{{- end -}}
{{- end -}}
{{- range $field := list "maxNamesPerRule" "maxMessageChars" -}}
{{- $v := index $r $field -}}
{{- if not (and (or (kindIs "float64" $v) (kindIs "int64" $v) (kindIs "int" $v)) (ge (int $v) 0)) -}}
{{- fail (printf "dailyReport.%s must be a number >= 0" $field) -}}
{{- end -}}
{{- end -}}
{{- if $r.alerts.enabled -}}
{{- if not (regexMatch "^[0-9]+[mh]$" (toString $r.alerts.lookback)) -}}
{{- fail (printf "dailyReport.alerts.lookback must be a duration like 9h, got %q" (toString $r.alerts.lookback)) -}}
{{- end -}}
{{- if not $r.alerts.checkDays -}}
{{- fail "dailyReport.alerts.checkDays must list days 0-6 (0 = Sunday)" -}}
{{- end -}}
{{- range $r.alerts.checkDays -}}
{{- if not (has (toString .) (list "0" "1" "2" "3" "4" "5" "6")) -}}
{{- fail (printf "dailyReport.alerts.checkDays: %q is not a day 0-6 (0 = Sunday)" (toString .)) -}}
{{- end -}}
{{- end -}}
{{- $from := $r.alerts.checkFromHour -}}
{{- $to := $r.alerts.checkToHour -}}
{{- if not (and (regexMatch "^[0-9]+$" (toString $from)) (regexMatch "^[0-9]+$" (toString $to)) (lt (int $from) (int $to)) (le (int $to) 24)) -}}
{{- fail "dailyReport.alerts needs 0 <= checkFromHour < checkToHour <= 24" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Labels of the daily-report objects (and, plus the mclabels, of its Pod). */}}
{{- define "gatekeeper-constraints.dailyReportLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}-daily-report
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
