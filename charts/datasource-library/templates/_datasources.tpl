{{/*
Generate Grafana provisioning YAML for all configured postgres datasources.

Datasource name follows the convention: team-service-environment

Environment resolution (first match wins):
  1. env field on the entry itself
  2. global.mclabels.environment
  3. error

Required per entry:
  team, service, host, database, username, password

Optional per entry:
  environment      override environment for this entry (default: global.mclabels.environment)
  version          (default: 1300)
  ssl:
    secretName     Kubernetes secret name; resolves cert paths to /etc/secrets/{secretName}/{certFile,keyFile,caFile}
    mode           (default: verify-full) — one of: require, verify-ca, verify-full
    certFile       override default path to client certificate
    keyFile        override default path to client private key
    rootCertFile   override default path to CA certificate

Example — environment from global:
  datasources:
    postgres:
      - team: infra
        service: jobnik
        host: hostname
        database: infra-jobnik
        username: mapcolonies
        password: mapcolonies-password

Example — environment per entry:
  datasources:
    postgres:
      - team: infra
        service: jobnik
        environment: prod
        host: hostname
        database: infra-jobnik
        username: mapcolonies
        ssl:
          secretName: pg-certs
*/}}
{{- define "datasource-library.postgres" -}}
{{- $globalEnvironment := dig "global" "mclabels" "environment" "" (toJson .Values | fromJson) -}}
apiVersion: 1
datasources:
  {{- range dig "datasources" "postgres" (list) .Values }}
  {{- $team    := required "datasource-library: 'team' is required on every datasources.postgres entry" .team -}}
  {{- $service := required (printf "datasource-library: 'service' is required (team: %s)" $team) .service -}}
  {{- $environment     := required (printf "datasource-library: entry '%s/%s' is missing an environment. Set 'environment' on the entry or set global.mclabels.environment" $team $service) (.environment | default $globalEnvironment) -}}
  {{- $name    := printf "%s-%s-%s" $team $service $environment }}
  {{- if .ssl }}
    {{- $_ := required (printf "datasource-library: 'ssl.secretName' is required when ssl is set (entry: %s/%s)" $team $service) .ssl.secretName -}}
    {{- if .ssl.mode }}
      {{- if not (has .ssl.mode (list "require" "verify-ca" "verify-full")) }}
        {{- fail (printf "datasource-library: ssl.mode '%s' is invalid (entry: %s/%s). Must be one of: require, verify-ca, verify-full" .ssl.mode $team $service) }}
      {{- end }}
    {{- end }}
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
      {{- $secretBase := printf "/etc/secrets/%s" .ssl.secretName }}
      sslmode: {{ .ssl.mode | default "verify-full" | quote }}
      sslCertFile: {{ .ssl.certFile | default (printf "%s/certFile" $secretBase) | quote }}
      sslKeyFile: {{ .ssl.keyFile | default (printf "%s/keyFile" $secretBase) | quote }}
      sslRootCertFile: {{ .ssl.rootCertFile | default (printf "%s/caFile" $secretBase) | quote }}
    {{- else }}
      sslmode: "disable"
    secureJsonData:
      password: {{ required (printf "datasource-library: 'password' is required (entry: %s/%s)" $team $service) .password | quote }}
    {{- end }}
  {{- end }}
{{- end }}
