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

{{/*
Secret holding a team's webhook: grafana-webhooks (created by this chart) when the team sets an
inline `url`, else alertingWebhooksSecret (created outside the chart).
  {{ include "grafana.webhookSecret" (dict "team" . "root" $) }}   (root: the grafana subchart)
*/}}
{{- define "grafana.webhookSecret" -}}
{{- if .team.url -}}
grafana-webhooks
{{- else -}}
{{- required (printf "grafana.alertingWebhooksSecret: required for team %q, which has no url" (toString .team.team)) .root.Values.alertingWebhooksSecret -}}
{{- end -}}
{{- end }}

{{/*
Adds one envValueFrom entry per team, read with secretKeyRef (optional: false). A key missing
from the Secret then keeps the new pod in CreateContainerConfigError ("couldn't find key") while
the old pod keeps serving, instead of Grafana starting with an empty contact point URL.
An entry already set in envValueFrom or env for the same name is left as is.
Called with the grafana subchart root; it only mutates .Values and renders nothing.
*/}}
{{- define "grafana.webhookEnvValueFrom" -}}
{{- if not (kindIs "map" .Values.envValueFrom) }}{{ $_ := set .Values "envValueFrom" dict }}{{ end }}
{{- $env := .Values.env | default dict }}
{{- range .Values.alertingTeamsWebhooks }}
{{- $name := include "grafana.webhookEnv" .team }}
{{- if not (or (hasKey $.Values.envValueFrom $name) (hasKey $env $name)) }}
{{- $ref := dict "name" (include "grafana.webhookSecret" (dict "team" . "root" $)) "key" $name "optional" false }}
{{- $_ := set $.Values.envValueFrom $name (dict "secretKeyRef" $ref) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Overrides the grafana subchart's helper of the same name (identical output). Upstream renders
envValueFrom from values only, with fixed names, so the per-team entries are added here: the
helper is the first include of "grafana.pod", before its env block. Named templates are global
and this chart's are parsed after the subchart's, so this definition wins.
Keep the body in sync with charts/grafana/templates/_helpers.tpl of the subchart.
*/}}
{{- define "grafana.serviceAccountName" -}}
{{- $_ := include "grafana.webhookEnvValueFrom" . -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "grafana.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
