{{/*
Helpers for templates/alerts.yaml (deploy-time Grafana alert rules).

How the rules are built
  files/alerts/gatekeeper-deploy.yaml is one Grafana rule with placeholders. Every rule is that
  file with the placeholders replaced (a plain string replace, because the file also holds
  Grafana's own {{ $labels.x }}, which must not go through Helm templating):
    __NAMESPACE_REGEX__  namespaces the whole alert covers (workloadPolicies scope)
    __ENTRY_FILTERS__    extra LogQL label filters that pick one team's namespaces
    __UID__ __TITLE__ __TEAM__
  There is one rule per namespaceTeams entry with a team, plus one fallback rule for everything
  else. A namespace must reach exactly one team, so each rule excludes the namespaces of the
  entries before it. Entries are ordered exact names first, then globs, in listed order.
  Entries with `silence: true` get no rule but are excluded from the later ones.

LogQL quoting
  The expression sits inside a double-quoted YAML string, so every quote inside the LogQL
  filters is written as \" (see deployAlertNsFilter).
*/}}

{{/* Loki regex for the namespaces the alerts cover. Fails when nothing is in scope. */}}
{{- define "gatekeeper-constraints.deployAlertScopeRegex" -}}
{{- $wp := .Values.workloadPolicies -}}
{{- $scope := $wp.warnNamespaces | default list -}}
{{- if .Values.deployAlerts.includeEnforcedNamespaces -}}
{{- $scope = concat $scope ($wp.enforcedNamespaces | default list) -}}
{{- end -}}
{{- if not $scope -}}
{{- fail "deployAlerts needs at least one namespace: set workloadPolicies.warnNamespaces (or enforcedNamespaces with deployAlerts.includeEnforcedNamespaces)" -}}
{{- end -}}
{{- $parts := list -}}
{{- range $scope -}}
{{- $parts = append $parts (include "gatekeeper-constraints.nsRegex" .) -}}
{{- end -}}
{{- printf "(%s)" (join "|" $parts) -}}
{{- end -}}

{{/* Validates deployAlerts.defaultTeam and returns it. */}}
{{- define "gatekeeper-constraints.deployAlertDefaultTeam" -}}
{{- $team := .Values.deployAlerts.defaultTeam -}}
{{- if not (regexMatch "^[a-z0-9_-]+$" (toString $team)) -}}
{{- fail (printf "deployAlerts.defaultTeam must be a team name like \"infra\", got %q" (toString $team)) -}}
{{- end -}}
{{- $team -}}
{{- end -}}

{{/*
Validates namespaceTeams and returns it as a YAML list in matching order (exact names first,
then globs, each group in listed order).
  {{- $entries := include "gatekeeper-constraints.deployAlertEntries" . | fromYamlArray }}
*/}}
{{- define "gatekeeper-constraints.deployAlertEntries" -}}
{{- $exact := list -}}
{{- $globs := list -}}
{{- range $i, $e := .Values.namespaceTeams | default list -}}
{{- if not (regexMatch "^[a-z0-9*?-]+$" (toString $e.namespace)) -}}
{{- fail (printf "namespaceTeams[%d].namespace %q must only contain a-z, 0-9, -, * and ?" $i (toString $e.namespace)) -}}
{{- end -}}
{{- if or (and $e.team $e.silence) (not (or $e.team $e.silence)) -}}
{{- fail (printf "namespaceTeams[%d]: set either team or silence: true" $i) -}}
{{- end -}}
{{- if and $e.team (not (regexMatch "^[a-z0-9_-]+$" (toString $e.team))) -}}
{{- fail (printf "namespaceTeams[%d].team must be a team name like \"raster\", got %q" $i (toString $e.team)) -}}
{{- end -}}
{{- if or (contains "*" $e.namespace) (contains "?" $e.namespace) -}}
{{- $globs = append $globs $e -}}
{{- else -}}
{{- $exact = append $exact $e -}}
{{- end -}}
{{- end -}}
{{- toYaml (concat $exact $globs) -}}
{{- end -}}

{{/*
One Grafana rule: the template file with the placeholders replaced.
  {{- include "gatekeeper-constraints.deployAlertRule" (dict "base" $base "filters" $filters "uid" "gk-deploy-raster-0" "title" "WorkloadPolicyViolationOnDeploy-raster-0" "team" "raster") }}
*/}}
{{- define "gatekeeper-constraints.deployAlertRule" -}}
{{- .base | replace "__ENTRY_FILTERS__" .filters | replace "__UID__" .uid | replace "__TITLE__" .title | replace "__TEAM__" .team -}}
{{- end -}}

{{/* ` | resource_namespace<op>"(<regex>)"` as a LogQL filter, quoted for the YAML string. op is =~ or !~. */}}
{{- define "gatekeeper-constraints.deployAlertNsFilter" -}}
{{- printf " | resource_namespace%s\\\"(%s)\\\"" .op .regex -}}
{{- end -}}
