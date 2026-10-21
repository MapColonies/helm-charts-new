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
Service and resource name: <release>-<app chart>-blackbox (<release>-blackbox when rendered on its own).
Must match blackbox-lib.exporterName, which builds prometheus.io/probe-exporter; tests/naming.sh checks that.
Not truncated, so two long names cannot collide: longer than 63 characters fails the render.
*/}}
{{- define "blackbox-exporter.fullname" -}}
{{- $app := include "blackbox-exporter.appName" . -}}
{{- $name := .Values.customExporter.fullnameOverride | default (ternary (printf "%s-%s-blackbox" .Release.Name $app) (printf "%s-blackbox" .Release.Name) (not (empty $app))) -}}
{{- if gt (len $name) 63 -}}
  {{- fail (printf "blackbox: exporter name %q is longer than 63 characters; set blackbox.customExporter.fullnameOverride" $name) -}}
{{- end -}}
{{- $name -}}
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
{{ toYaml (mergeOverwrite $labels (.Values.customExporter.podLabels | default dict)) }}
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
{{- if not (regexMatch "^([0-9]+(ms|s|m|h))+$" (toString $ce.timeout)) -}}
  {{- fail (printf "blackbox.customExporter.timeout must be a duration like 5s or 500ms, got %q" (toString $ce.timeout)) -}}
{{- end -}}
{{- $rules := $ce.rules | default dict -}}
{{- with $rules.validStatusCodes -}}
  {{- if not (kindIs "slice" .) -}}
    {{- fail "blackbox.customExporter.rules.validStatusCodes must be a list of HTTP status codes" -}}
  {{- end -}}
  {{- range . -}}
    {{- if not (or (kindIs "float64" .) (kindIs "int64" .) (kindIs "int" .)) -}}
      {{- fail (printf "blackbox.customExporter.rules.validStatusCodes must be numbers, got %q" (toString .)) -}}
    {{- end -}}
    {{- if or (lt (float64 .) 100.0) (gt (float64 .) 599.0) -}}
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
    {{- /* Same Go regexp package as the exporter: an invalid or unsupported regex (e.g. a lookahead) fails here
           instead of crash-looping the exporter after the upgrade. */ -}}
    {{- $_ := mustRegexMatch . "" -}}
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
