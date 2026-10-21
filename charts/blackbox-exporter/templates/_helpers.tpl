{{/*
Name of the app chart that includes this subchart. .Chart.Name is the alias ("blackbox") here, so it is read from
the template path, e.g. raster-serving/charts/mapproxy-api/charts/blackbox/templates -> mapproxy-api.
Empty when this chart is rendered on its own.
*/}}
{{- define "blackbox-exporter.appName" -}}
{{- $parts := splitList "/" .Template.BasePath -}}
{{- if ge (len $parts) 4 -}}
{{- index $parts (sub (len $parts) 4) -}}
{{- end -}}
{{- end }}

{{/*
Service and resource name: <release>-<app chart>-blackbox, or <release>-blackbox when the release name already
contains the app chart name. Must match blackbox-lib.exporterName, which builds prometheus.io/probe-exporter.
*/}}
{{- define "blackbox-exporter.fullname" -}}
{{- $app := include "blackbox-exporter.appName" . -}}
{{- if .Values.customExporter.fullnameOverride -}}
{{- .Values.customExporter.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if or (not $app) (contains $app .Release.Name) -}}
{{- printf "%s-blackbox" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s-blackbox" .Release.Name $app | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Selects this exporter's Pods only, also when one release holds several exporters.
*/}}
{{- define "blackbox-exporter.selectorLabels" -}}
app.kubernetes.io/name: blackbox-exporter
app.kubernetes.io/instance: {{ include "blackbox-exporter.fullname" . }}
{{- end }}

{{- define "blackbox-exporter.labels" -}}
{{ include "blackbox-exporter.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.customExporter.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/*
Pod labels: common labels, mclabels defaults from global.mclabels, then customExporter.podLabels.
*/}}
{{- define "blackbox-exporter.podLabels" -}}
{{- $global := (.Values.global | default dict).mclabels | default dict -}}
{{- $labels := dict "mapcolonies.io/component" "monitoring" "mapcolonies.io/part-of" "blackbox" -}}
{{- with $global.environment }}{{ $_ := set $labels "mapcolonies.io/environment" . }}{{ end }}
{{- with $global.owner }}{{ $_ := set $labels "mapcolonies.io/owner" . }}{{ end }}
{{- include "blackbox-exporter.labels" . }}
{{ toYaml (mergeOverwrite $labels .Values.customExporter.podLabels) }}
{{- end }}

{{- define "blackbox-exporter.image" -}}
{{- $image := .Values.customExporter.image -}}
{{- $cloud := (.Values.global | default dict).cloudProvider | default dict -}}
{{- $registry := $image.registry | default $cloud.dockerRegistryUrl | default (.Values.global | default dict).imageRegistry -}}
{{- printf "%s%s:%s" (ternary (printf "%s/" $registry) "" (not (empty $registry))) $image.repository $image.tag -}}
{{- end }}

{{- define "blackbox-exporter.imagePullSecretName" -}}
{{- $cloud := (.Values.global | default dict).cloudProvider | default dict -}}
{{- .Values.customExporter.imagePullSecretName | default $cloud.imagePullSecretName | default (.Values.global | default dict).imagePullSecretName | default "" -}}
{{- end }}

{{/*
Probe scheme, same rule as blackbox-lib: target.scheme, else https when target.host is set, else http.
*/}}
{{- define "blackbox-exporter.scheme" -}}
{{- $target := .Values.target | default dict -}}
{{- $target.scheme | default (ternary "https" "http" (not (empty $target.host))) -}}
{{- end }}

{{- define "blackbox-exporter.validate" -}}
{{- $ce := .Values.customExporter -}}
{{- if not .Values.module -}}
  {{- fail "blackbox.module is required when blackbox.customExporter.enabled is true" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_-]+$" .Values.module) -}}
  {{- fail (printf "blackbox.module may only contain letters, digits, \"_\" and \"-\", got %q" .Values.module) -}}
{{- end -}}
{{- $rules := $ce.rules | default dict -}}
{{- with $rules.validStatusCodes -}}
  {{- if not (kindIs "slice" .) -}}
    {{- fail "blackbox.customExporter.rules.validStatusCodes must be a list of HTTP status codes" -}}
  {{- end -}}
  {{- range . -}}
    {{- if or (not (or (kindIs "float64" .) (kindIs "int64" .) (kindIs "int" .))) (lt (float64 .) 100.0) (gt (float64 .) 599.0) -}}
      {{- fail (printf "blackbox.customExporter.rules.validStatusCodes: %v is not an HTTP status code (100-599)" .) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- with $rules.bodyRegexMatch -}}
  {{- if not (kindIs "slice" .) -}}
    {{- fail "blackbox.customExporter.rules.bodyRegexMatch must be a list of regular expressions" -}}
  {{- end -}}
  {{- range . -}}
    {{- if not (kindIs "string" .) -}}
      {{- fail (printf "blackbox.customExporter.rules.bodyRegexMatch: %v is not a string" .) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- with $rules.headers -}}
  {{- if not (kindIs "map" .) -}}
    {{- fail "blackbox.customExporter.rules.headers must be a map of header name to value" -}}
  {{- end -}}
  {{- range $name, $value := . -}}
    {{- if not (kindIs "string" $value) -}}
      {{- fail (printf "blackbox.customExporter.rules.headers.%s must be a string, got %v" $name $value) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
blackbox.yaml with one module named after blackbox.module, generated from customExporter.rules.
*/}}
{{- define "blackbox-exporter.config" -}}
{{- $ce := .Values.customExporter -}}
{{- $rules := $ce.rules | default dict -}}
{{- $http := dict "preferred_ip_protocol" "ip4" "follow_redirects" true "valid_http_versions" (list "HTTP/1.1" "HTTP/2.0") -}}
{{- with $rules.validStatusCodes }}{{ $_ := set $http "valid_status_codes" . }}{{ end -}}
{{- with $rules.bodyRegexMatch }}{{ $_ := set $http "fail_if_body_not_matches_regexp" . }}{{ end -}}
{{- with $rules.headers }}{{ $_ := set $http "headers" . }}{{ end -}}
{{- if eq (include "blackbox-exporter.scheme" .) "https" }}{{ $_ := set $http "fail_if_not_ssl" true }}{{ end -}}
{{- $module := dict "prober" "http" "timeout" $ce.timeout "http" $http -}}
{{- toYaml (dict "modules" (dict .Values.module $module)) -}}
{{- end }}
