{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "openshift-route.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openshift-route.labels" -}}
helm.sh/chart: {{ include "openshift-route.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "openshift-route.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
