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
