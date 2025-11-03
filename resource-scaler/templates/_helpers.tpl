{{/*
Expand the name of the chart.
*/}}
{{- define "resource-scaler.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "resource-scaler.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "resource-scaler.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "resource-scaler.labels" -}}
helm.sh/chart: {{ include "resource-scaler.chart" . }}
{{ include "resource-scaler.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "mclabels.labels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "resource-scaler.selectorLabels" -}}
app.kubernetes.io/name: {{ include "resource-scaler.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{ include "mclabels.selectorLabels" . }}
{{- end }}

{{/*
Generate args for the scaler command
*/}}
{{- define "resource-scaler.args" -}}
{{- $root := index . 0 -}}
{{- $base := index . 1 -}}
{{- $args := $base -}}
{{- /* Append namespaces as repeated --namespace flags if provided */ -}}
{{- if $root.Values.namespaces -}}
	{{- range $ns := $root.Values.namespaces -}}
		{{- $args = append $args "--namespace" -}}
		{{- $args = append $args $ns -}}
	{{- end -}}
{{- end -}}
{{- if $root.Values.targetRelease -}}
{{- $args = append $args "--release" $root.Values.targetRelease -}}
{{- end -}}
{{- if $root.Values.debug -}}
{{- $args = append $args "--debug" -}}
{{- end -}}
{{- if and $root.Values.slack.enabled $root.Values.slack.secretName -}}
{{/* Slack webhook will be read from env var SLACK_WEBHOOK_URL by the app */}}
{{- end -}}
{{- /* Append any user-provided extraArgs at the very end, preserving ordering */ -}}
{{- if $root.Values.extraArgs -}}
	{{- range $a := $root.Values.extraArgs -}}
		{{- $args = append $args $a -}}
	{{- end -}}
{{- end -}}
{{- toYaml $args -}}
{{- end }}
