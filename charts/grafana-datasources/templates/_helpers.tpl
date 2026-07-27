{{/*
Owning team (instance-level, required).
*/}}
{{- define "grafana-datasources.team" -}}
{{- required "grafana-datasources: 'team' is required" .Values.team -}}
{{- end -}}

{{/*
Environment (instance-level). Resolves from .Values.environment, then
global.mclabels.environment, else fails.
*/}}
{{- define "grafana-datasources.environment" -}}
{{- $global := dig "global" "mclabels" "environment" "" (toJson .Values | fromJson) -}}
{{- required "grafana-datasources: 'environment' is required. Set 'environment' or global.mclabels.environment" (.Values.environment | default $global) -}}
{{- end -}}

{{/*
Base name for the Secret and its provisioning file:
  {team}-{environment}[-{instance}]
The optional 'instance' disambiguates multiple datasource sets that share the
same team and environment within one release (e.g. several services in an umbrella).
*/}}
{{- define "grafana-datasources.basename" -}}
{{- $base := printf "%s-%s" (include "grafana-datasources.team" .) (include "grafana-datasources.environment" .) -}}
{{- if .Values.instance -}}
{{- $base = printf "%s-%s" $base .Values.instance -}}
{{- end -}}
{{- $base | trunc 63 | trimSuffix "-" -}}
{{- end -}}
