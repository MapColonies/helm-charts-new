{{/*
Env var (and Secret key) holding a team's webhook URL: <TEAM>_WEBHOOK, team upper-cased with
"-" as "_". A team starting with a digit gets a TEAM_ prefix (3d -> TEAM_3D_WEBHOOK), because
envFrom skips names that are not valid env var names, which cannot start with a digit.
  {{ include "grafana.webhookEnv" .team }}
*/}}
{{- define "grafana.webhookEnv" -}}
{{- if not (regexMatch "^[a-z0-9_-]+$" (toString .)) -}}
{{- fail (printf "grafana.alertingTeamsWebhooks: team %q must only contain a-z, 0-9, - and _" (toString .)) -}}
{{- end -}}
{{- $name := upper (toString .) | replace "-" "_" -}}
{{- if regexMatch "^[0-9]" $name -}}{{ $name = printf "TEAM_%s" $name }}{{- end -}}
{{- printf "%s_WEBHOOK" $name -}}
{{- end }}
