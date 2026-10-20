{{/*
Defaults for the `blackbox:` values block. Keep in sync with values.yaml.
*/}}
{{- define "blackbox-lib.defaults" -}}
enabled: false
serviceName: ""
servicePort: ""
target:
  host: ""
  scheme: ""
  path: /liveness
  port: ""
customExporter:
  enabled: false
  moduleName: ""
  port: 9115
  fullnameOverride: ""
alerts:
  enabled: false
{{- end }}

{{/*
The parent's `blackbox:` block merged over the defaults, as YAML.
Usage: include "blackbox-lib.config" $ | fromYaml
*/}}
{{- define "blackbox-lib.config" -}}
{{- $defaults := include "blackbox-lib.defaults" . | fromYaml -}}
{{- $user := deepCopy (.Values.blackbox | default dict) -}}
{{- toYaml (mergeOverwrite $defaults $user) -}}
{{- end }}

{{/*
Name of the custom exporter Service deployed by the blackbox-exporter subchart: <release>-<app chart>-blackbox,
or <release>-blackbox when the release name already contains the chart name. Unique per app, also when an
umbrella release holds several apps. Must match blackbox-exporter.fullname.
Usage: include "blackbox-lib.exporterName" $  (the app chart's root context)
*/}}
{{- define "blackbox-lib.exporterName" -}}
{{- $cfg := include "blackbox-lib.config" . | fromYaml -}}
{{- if $cfg.customExporter.fullnameOverride -}}
{{- $cfg.customExporter.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains .Chart.Name .Release.Name -}}
{{- printf "%s-blackbox" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s-blackbox" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Prometheus probe annotations for the application's Service. Prints nothing when blackbox.enabled is false.

Usage, chart with .Values.service.name/.port:
  annotations:
    {{- include "blackbox-lib.serviceAnnotations" . | nindent 4 }}

Usage, chart that computes the Service name/port:
  annotations:
    {{- include "blackbox-lib.serviceAnnotations" (dict "ctx" . "name" (include "my-chart.fullname" .) "port" .Values.server.port) | nindent 4 }}
*/}}
{{- define "blackbox-lib.serviceAnnotations" -}}
{{- $ctx := . -}}
{{- $name := "" -}}
{{- $port := "" -}}
{{- if hasKey . "ctx" -}}
  {{- $ctx = .ctx -}}
  {{- $name = .name | default "" -}}
  {{- $port = .port | default "" -}}
{{- else if .Values.service -}}
  {{- $name = .Values.service.name | default "" -}}
  {{- $port = .Values.service.port | default "" -}}
{{- end -}}
{{- $cfg := include "blackbox-lib.config" $ctx | fromYaml -}}
{{- if $cfg.enabled -}}
  {{- $name = $cfg.serviceName | default $name -}}
  {{- $port = $cfg.servicePort | default $port -}}
  {{- $target := $cfg.target -}}
  {{- $host := $target.host -}}
  {{- if not $host -}}
    {{- if not $name -}}
      {{- fail "blackbox: Service name is unknown. Set service.name, blackbox.serviceName, or pass \"name\" to blackbox-lib.serviceAnnotations (or set blackbox.target.host)" -}}
    {{- end -}}
    {{- $probePort := $target.port | default $port -}}
    {{- if not $probePort -}}
      {{- fail "blackbox: Service port is unknown. Set service.port, blackbox.servicePort or blackbox.target.port, or pass \"port\" to blackbox-lib.serviceAnnotations" -}}
    {{- end -}}
    {{- $host = printf "%s.%s.svc:%v" $name $ctx.Release.Namespace $probePort -}}
  {{- end -}}
  {{- $scheme := $target.scheme | default (ternary "https" "http" (not (empty $target.host))) -}}
  {{- if not (has $scheme (list "http" "https")) -}}
    {{- fail (printf "blackbox.target.scheme must be \"http\" or \"https\", got %q" $scheme) -}}
  {{- end -}}
  {{- if not (hasPrefix "/" $target.path) -}}
    {{- fail (printf "blackbox.target.path must start with \"/\", got %q" $target.path) -}}
  {{- end -}}
prometheus.io/probe: "true"
prometheus.io/probe-host: {{ $host | quote }}
prometheus.io/probe-scheme: {{ $scheme | quote }}
prometheus.io/probe-path: {{ $target.path | quote }}
  {{- if $cfg.customExporter.enabled }}
    {{- if not $cfg.customExporter.moduleName -}}
      {{- fail "blackbox.customExporter.moduleName is required when blackbox.customExporter.enabled is true" -}}
    {{- end }}
prometheus.io/probe-exporter: {{ printf "%s.%s.svc:%v" (include "blackbox-lib.exporterName" $ctx) $ctx.Release.Namespace $cfg.customExporter.port | quote }}
prometheus.io/probe-module: {{ $cfg.customExporter.moduleName | quote }}
  {{- end }}
{{- end -}}
{{- end }}
