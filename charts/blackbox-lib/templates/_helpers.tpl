{{/*
Defaults for the `blackbox:` values block. Keep in sync with values.yaml.
*/}}
{{- define "blackbox-lib.defaults" -}}
enabled: false
module: ""
target:
  host: ""
  scheme: ""
  path: /liveness
  port: ""
customExporter:
  enabled: false
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
unique per app, also when an umbrella release holds several apps. Not truncated, so two long names cannot
collide: longer than 63 characters fails the render. Must match blackbox-exporter.fullname.
Usage: include "blackbox-lib.exporterName" $  (the app chart's root context)
*/}}
{{- define "blackbox-lib.exporterName" -}}
{{- $cfg := include "blackbox-lib.config" . | fromYaml -}}
{{- $name := $cfg.customExporter.fullnameOverride | default (printf "%s-%s-blackbox" .Release.Name .Chart.Name) -}}
{{- if gt (len $name) 63 -}}
  {{- fail (printf "blackbox: exporter name %q is longer than 63 characters; set blackbox.customExporter.fullnameOverride" $name) -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{/*
Prometheus probe annotations for the application's Service. Prints nothing when blackbox.enabled is false.
Prometheus probes the Service's own discovered address unless blackbox.target.host is set.

Usage:
  annotations:
    {{- include "blackbox-lib.serviceAnnotations" . | nindent 4 }}
*/}}
{{- define "blackbox-lib.serviceAnnotations" -}}
{{- $cfg := include "blackbox-lib.config" . | fromYaml -}}
{{- if $cfg.enabled -}}
  {{- $target := $cfg.target -}}
  {{- $scheme := $target.scheme | default (ternary "https" "http" (not (empty $target.host))) -}}
  {{- if not (has $scheme (list "http" "https")) -}}
    {{- fail (printf "blackbox.target.scheme must be \"http\" or \"https\", got %q" $scheme) -}}
  {{- end -}}
  {{- if not (hasPrefix "/" $target.path) -}}
    {{- fail (printf "blackbox.target.path must start with \"/\", got %q" $target.path) -}}
  {{- end -}}
  {{- $port := toString $target.port -}}
  {{- if and $target.port (not (regexMatch "^[1-9][0-9]{0,4}$" $port)) -}}
    {{- fail (printf "blackbox.target.port must be a port number, got %q" $port) -}}
  {{- end -}}
  {{- if and $cfg.module (not (regexMatch "^[A-Za-z0-9_-]+$" $cfg.module)) -}}
    {{- fail (printf "blackbox.module may only contain letters, digits, \"_\" and \"-\", got %q" $cfg.module) -}}
  {{- end -}}
  {{- if and $cfg.customExporter.enabled (not $cfg.module) -}}
    {{- fail "blackbox.module is required when blackbox.customExporter.enabled is true" -}}
  {{- end -}}
prometheus.io/probe: "true"
  {{- with $target.host }}
prometheus.io/probe-host: {{ . | quote }}
  {{- end }}
prometheus.io/probe-scheme: {{ $scheme | quote }}
prometheus.io/probe-path: {{ $target.path | quote }}
  {{- if $target.port }}
prometheus.io/probe-port: {{ $port | quote }}
  {{- end }}
  {{- with $cfg.module }}
prometheus.io/probe-module: {{ . | quote }}
  {{- end }}
  {{- if $cfg.customExporter.enabled }}
prometheus.io/probe-exporter: {{ printf "%s.%s.svc:%v" (include "blackbox-lib.exporterName" $) $.Release.Namespace $cfg.customExporter.port | quote }}
  {{- end }}
{{- end -}}
{{- end }}
