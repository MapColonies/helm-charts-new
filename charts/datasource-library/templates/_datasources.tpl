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
    mode           (default: verify-full) — one of: require, verify-ca, verify-full
    certFile       the path to the client certificate file
    keyFile        the path to the client key file
    rootCertFile   the path to the root CA certificate file

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
          certFile: /etc/secrets/pg-certs/certFile
          keyFile: /etc/secrets/pg-certs/keyFile
          rootCertFile: /etc/secrets/pg-certs/caFile
*/}}
{{- define "datasource-library.postgres" -}}
{{- $globalEnvironment := dig "global" "mclabels" "environment" "" (toJson .Values | fromJson) -}}
apiVersion: 1
datasources:
  {{- range dig "datasources" "postgres" (list) (toJson .Values | fromJson) }}
  {{- $team    := required "datasource-library: 'team' is required on every datasources.postgres entry" .team -}}
  {{- $service := required (printf "datasource-library: 'service' is required (team: %s)" $team) .service -}}
  {{- $environment     := required (printf "datasource-library: entry '%s/%s' is missing an environment. Set 'environment' on the entry or set global.mclabels.environment" $team $service) (.environment | default $globalEnvironment) -}}
  {{- $name    := printf "%s-%s-%s" $team $service $environment }}
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
      {{- if and .ssl.mode (not (has .ssl.mode (list "require" "verify-ca" "verify-full"))) }}
        {{- fail (printf "datasource-library: ssl.mode '%s' is invalid (entry: %s/%s). Must be one of: require, verify-ca, verify-full" .ssl.mode $team $service) }}
      {{- end }}
      sslmode: {{ .ssl.mode | default "verify-full" | quote }}
      sslCertFile: {{ required (printf "datasource-library: 'ssl.certFile' is required when ssl is set (entry: %s/%s)" $team $service) .ssl.certFile | quote }}
      sslKeyFile: {{ required (printf "datasource-library: 'ssl.keyFile' is required when ssl is set (entry: %s/%s)" $team $service) .ssl.keyFile | quote }}
      sslRootCertFile: {{ required (printf "datasource-library: 'ssl.rootCertFile' is required when ssl is set (entry: %s/%s)" $team $service) .ssl.rootCertFile | quote }}
    {{- else }}
      sslmode: "disable"
    secureJsonData:
      password: {{ required (printf "datasource-library: 'password' is required (entry: %s/%s)" $team $service) .password | quote }}
    {{- end }}
  {{- end }}
{{- end }}
