{{/*
Generate Grafana provisioning YAML for all configured postgres datasources.

This define produces the raw provisioning content only; templates/datasources-secret.yaml
wraps it into a Secret that the Grafana k8s-sidecar picks up.

Datasource name follows the convention: team-service-environment
  team         instance-level (.Values.team)
  environment  instance-level (.Values.environment or global.mclabels.environment)
  service      per-entry

Required per entry:
  service, host, database, username

Auth (at least one required per entry):
  password                 password auth
  ssl.certFile + keyFile   client-certificate auth (both required together)

Optional per entry:
  version          (default: 1300)
  ssl:
    mode           (default: require) — one of: require, verify-ca, verify-full
    certFile       path to client certificate (must be mounted into Grafana)
    keyFile        path to client private key (must be mounted into Grafana)
    rootCertFile   path to CA certificate (required for verify-ca and verify-full)
*/}}
{{- define "datasource-library.postgres" -}}
{{- $team := include "datasource-library.team" . -}}
{{- $environment := include "datasource-library.environment" . -}}
apiVersion: 1
datasources:
  {{- range dig "datasources" "postgres" (list) (toJson .Values | fromJson) }}
  {{- $service := required "datasource-library: 'service' is required on every datasources.postgres entry" .service -}}
  {{- $name := printf "%s-%s-%s" $team $service $environment -}}
  {{- $ssl := .ssl | default dict -}}
  {{- $mode := $ssl.mode | default "require" -}}
  {{- $hasPassword := not (empty .password) -}}
  {{- $hasCert := not (empty $ssl.certFile) -}}
  {{- $hasKey := not (empty $ssl.keyFile) -}}
  {{- if ne $hasCert $hasKey -}}
    {{- fail (printf "datasource-library: entry '%s/%s' has an incomplete client certificate. Provide both 'ssl.certFile' and 'ssl.keyFile', or neither" $team $service) -}}
  {{- end -}}
  {{- $hasClientCert := and $hasCert $hasKey -}}
  {{- if not (or $hasPassword $hasClientCert) -}}
    {{- fail (printf "datasource-library: entry '%s/%s' has no auth method. Provide 'password', or a client certificate ('ssl.certFile' and 'ssl.keyFile')" $team $service) -}}
  {{- end }}
  - name: {{ $name }}
    uid: {{ $name }}
    type: grafana-postgresql-datasource
    url: {{ required (printf "datasource-library: 'host' is required (entry: %s/%s)" $team $service) .host | quote }}
    user: {{ required (printf "datasource-library: 'username' is required (entry: %s/%s)" $team $service) .username | quote }}
    isDefault: false
    editable: false
    jsonData:
      database: {{ required (printf "datasource-library: 'database' is required (entry: %s/%s)" $team $service) .database | quote }}
      postgresVersion: {{ .version | default 1300 }}
    {{- if .ssl }}
      sslmode: {{ $mode | quote }}
      {{- if $hasClientCert }}
      sslCertFile: {{ $ssl.certFile | quote }}
      sslKeyFile: {{ $ssl.keyFile | quote }}
      {{- end }}
      {{- if $ssl.rootCertFile }}
      sslRootCertFile: {{ $ssl.rootCertFile | quote }}
      {{- end }}
    {{- else }}
      sslmode: "disable"
    {{- end }}
    {{- if $hasPassword }}
    secureJsonData:
      password: {{ .password | quote }}
    {{- end }}
  {{- end }}
{{- end }}
