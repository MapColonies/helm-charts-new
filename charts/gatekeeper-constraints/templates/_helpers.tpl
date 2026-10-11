{{/*
workloadConstraint renders one Constraint of a workload rule for Deployments and
StatefulSets, matched to the namespaces of its enforcement action, with the
exemption list entries of that rule as parameters. It renders nothing when that
namespace list is empty, because an empty list would match every namespace in
Gatekeeper.

Usage:
  {{- include "gatekeeper-constraints.workloadConstraint" (dict "root" . "rule" "cpuRatio" "kind" "K8sWorkloadCpuRatio" "name" "workload-cpu-ratio" "action" "warn") }}
*/}}
{{- define "gatekeeper-constraints.workloadConstraint" -}}
{{- $policies := .root.Values.workloadPolicies -}}
{{- $namespaces := ternary $policies.warnNamespaces $policies.enforcedNamespaces (eq .action "warn") -}}
{{- $exemptions := include "gatekeeper-constraints.workloadExemptions" (dict "root" .root "rule" .rule) | fromYamlArray -}}
{{- if $namespaces }}
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: {{ .kind }}
metadata:
  name: {{ .name }}-{{ .action }}
spec:
  enforcementAction: {{ .action | quote }}
  match:
    scope: Namespaced
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment", "StatefulSet"]
    namespaces:
      {{- toYaml $namespaces | nindent 6 }}
  parameters:
    exemptions:
      {{- if $exemptions }}
      {{- toYaml $exemptions | nindent 6 }}
      {{- else }} []
      {{- end }}
{{- end }}
{{- end -}}

{{/*
workloadExemptions validates workloadPolicies.exemptions and returns, as a YAML
list, the entries that exempt a workload from <rule>. Rendering fails on an entry
without a namespace, kind, name or reason, with an unknown kind, or with an
unknown or empty rules list.

Usage:
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
workloadRego returns a chart file holding Rego, and fails when it is missing or
empty, so a wrong path can't render a ConstraintTemplate without its policy.

Usage:
  {{- include "gatekeeper-constraints.workloadRego" (dict "root" . "path" "rego/workload-cpu-ratio.rego") | nindent 8 }}
*/}}
{{- define "gatekeeper-constraints.workloadRego" -}}
{{- .root.Files.Get .path | required (printf "chart file %s is missing or empty" .path) -}}
{{- end -}}
