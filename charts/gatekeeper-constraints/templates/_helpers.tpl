{{/*
workloadConstraint renders one Constraint of a workload policy for Deployments and
StatefulSets, matched to the namespaces of its enforcement action. It renders
nothing when that namespace list is empty, because an empty list would match
every namespace in Gatekeeper.

Usage:
  {{- include "gatekeeper-constraints.workloadConstraint" (dict "root" . "kind" "K8sWorkloadCpuRatio" "name" "workload-cpu-ratio" "action" "warn") }}
*/}}
{{- define "gatekeeper-constraints.workloadConstraint" -}}
{{- $policies := .root.Values.workloadPolicies -}}
{{- $namespaces := ternary $policies.warnNamespaces $policies.enforcedNamespaces (eq .action "warn") -}}
{{- if $namespaces }}
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: {{ .kind }}
metadata:
  name: {{ .name }}-{{ .action }}
spec:
  enforcementAction: {{ .action }}
  match:
    scope: Namespaced
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment", "StatefulSet"]
    namespaces:
      {{- toYaml $namespaces | nindent 6 }}
{{- end }}
{{- end -}}
