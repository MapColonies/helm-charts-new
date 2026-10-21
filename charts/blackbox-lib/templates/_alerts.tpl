{{/*
Grafana alert rules for the app's Blackbox probes, as a ConfigMap that Grafana's alerts sidecar loads (label
mapcolonies.io/grafana-alerts). Rendered only when blackbox.enabled and blackbox.alerts.enabled are true.
The rules select the probe metrics by the Service's name and namespace, the labels the blackbox-services
scrape job puts on them, so the Service name has to be passed in.

Usage, in templates/monitoring.yaml:
  {{- include "blackbox-lib.grafanaAlertsConfigMap" (dict "ctx" . "service" (include "my-chart.fullname" .)) }}
*/}}
{{- define "blackbox-lib.grafanaAlertsConfigMap" -}}
{{- if not (and (kindIs "map" .) (hasKey . "ctx") (hasKey . "service")) -}}
  {{- fail "blackbox-lib.grafanaAlertsConfigMap needs the Service name: include \"blackbox-lib.grafanaAlertsConfigMap\" (dict \"ctx\" . \"service\" (include \"<chart>.fullname\" .))" -}}
{{- end -}}
{{- $ctx := .ctx -}}
{{- $service := .service -}}
{{- $cfg := include "blackbox-lib.config" $ctx | fromYaml -}}
{{- $alerts := $cfg.alerts | default dict -}}
{{- if and $cfg.enabled $alerts.enabled -}}
  {{- if not $service -}}
    {{- fail "blackbox-lib.grafanaAlertsConfigMap: the \"service\" argument is empty" -}}
  {{- end -}}
  {{- $ns := $ctx.Release.Namespace -}}
  {{- $mclabels := $ctx.Values.mclabels | default dict -}}
  {{- $globalMclabels := ($ctx.Values.global | default dict).mclabels | default dict -}}
  {{- $team := $alerts.team | default $mclabels.owner | default $globalMclabels.owner | default "" -}}
  {{- if not $team -}}
    {{- fail "blackbox.alerts.team is unknown: set mclabels.owner (or blackbox.alerts.team) so the alerts can be routed" -}}
  {{- end -}}
  {{- if not (regexMatch "^[a-z0-9-]+$" $team) -}}
    {{- fail (printf "blackbox.alerts.team must be lowercase letters, digits and \"-\", got %q" $team) -}}
  {{- end -}}
  {{- $extraLabels := $alerts.extraLabels | default dict -}}
  {{- $extraAnnotations := $alerts.extraAnnotations | default dict -}}
  {{- range $key := list "service" "namespace" "alert_team" "severity" -}}
    {{- if hasKey $extraLabels $key -}}
      {{- fail (printf "blackbox.alerts.extraLabels.%s is reserved: the alert sets it itself" $key) -}}
    {{- end -}}
  {{- end -}}
  {{- $datasource := $alerts.datasourceUid | default "prometheus" -}}
  {{- $selector := printf "{namespace=%q,service=%q}" $ns $service -}}
  {{- $rules := $alerts.rules | default dict -}}
  {{- $out := list -}}

  {{- /* availability: on unless rules.availability.enabled is false */ -}}
  {{- $r := $rules.availability | default dict -}}
  {{- if or (not (hasKey $r "enabled")) $r.enabled -}}
    {{- $out = append $out (dict "rule" "availability" "title" "is down" "for" ($r.downDuration | default "1m") "forKey" "downDuration"
          "severity" ($r.severity | default "critical") "expr" (printf "probe_success%s" $selector) "op" "lt" "threshold" 1
          "summary" (printf "%s is down" $service)
          "description" (printf "The Blackbox probe of {{ $labels.instance }} (service %s in namespace %s) is failing." $service $ns)) -}}
  {{- end -}}

  {{- /* latency: only when rules.latency.enabled */ -}}
  {{- $r = $rules.latency | default dict -}}
  {{- if $r.enabled -}}
    {{- $max := $r.maxSeconds | default 1 -}}
    {{- if not (and (or (kindIs "float64" $max) (kindIs "int64" $max) (kindIs "int" $max)) (gt (float64 $max) 0.0)) -}}
      {{- fail (printf "blackbox.alerts.rules.latency.maxSeconds must be a number above 0, got %v" $max) -}}
    {{- end -}}
    {{- $out = append $out (dict "rule" "latency" "title" "is slow" "for" ($r.forDuration | default "5m") "forKey" "latency.forDuration"
          "severity" ($r.severity | default "warning") "expr" (printf "probe_duration_seconds%s" $selector) "op" "gt" "threshold" $max
          "summary" (printf "%s responds slowly" $service)
          "description" (printf "The Blackbox probe of {{ $labels.instance }} (service %s in namespace %s) takes longer than %vs." $service $ns $max)) -}}
  {{- end -}}

  {{- /* sslExpiry: only when rules.sslExpiry.enabled */ -}}
  {{- $r = $rules.sslExpiry | default dict -}}
  {{- if $r.enabled -}}
    {{- $days := $r.warningDays | default 21 -}}
    {{- if not (and (or (kindIs "float64" $days) (kindIs "int64" $days) (kindIs "int" $days)) (gt (float64 $days) 0.0)) -}}
      {{- fail (printf "blackbox.alerts.rules.sslExpiry.warningDays must be a number above 0, got %v" $days) -}}
    {{- end -}}
    {{- $out = append $out (dict "rule" "ssl-expiry" "title" "certificate expires soon" "for" ($r.forDuration | default "1h") "forKey" "sslExpiry.forDuration"
          "severity" ($r.severity | default "warning") "expr" (printf "(probe_ssl_earliest_cert_expiry%s - time()) / 86400" $selector) "op" "lt" "threshold" $days
          "summary" (printf "The certificate of %s expires soon" $service)
          "description" (printf "The TLS certificate of {{ $labels.instance }} (service %s in namespace %s) expires in less than %v days." $service $ns $days)) -}}
  {{- end -}}

  {{- if $out -}}
    {{- $grafanaRules := list -}}
    {{- range $out -}}
      {{- if not (has .severity (list "critical" "warning" "info")) -}}
        {{- fail (printf "blackbox.alerts.rules severity must be critical, warning or info, got %q" .severity) -}}
      {{- end -}}
      {{- if not (regexMatch "^([0-9]+(s|m|h|d|w))+$" (toString .for)) -}}
        {{- fail (printf "blackbox.alerts.rules.%s must be a duration like 1m or 1h30m, got %q" .forKey (toString .for)) -}}
      {{- end -}}
      {{- $labels := merge (dict "alert_team" $team "severity" .severity "service" $service "namespace" $ns) $extraLabels -}}
      {{- $annotations := merge (dict "summary" .summary "description" .description) $extraAnnotations -}}
      {{- $query := dict "refId" "A" "relativeTimeRange" (dict "from" 600 "to" 0) "datasourceUid" $datasource
            "model" (dict "refId" "A" "expr" .expr "instant" true "intervalMs" 1000 "maxDataPoints" 43200
                          "datasource" (dict "type" "prometheus" "uid" $datasource)) -}}
      {{- $threshold := dict "refId" "C" "relativeTimeRange" (dict "from" 600 "to" 0) "datasourceUid" "__expr__"
            "model" (dict "refId" "C" "type" "threshold" "expression" "A"
                          "conditions" (list (dict "evaluator" (dict "type" .op "params" (list .threshold))))
                          "datasource" (dict "type" "__expr__" "uid" "__expr__")) -}}
      {{- $grafanaRules = append $grafanaRules (dict
            "uid" (printf "bb-%s" (sha256sum (printf "%s/%s/%s" $ns $service .rule) | trunc 37))
            "title" (printf "%s (%s) %s" $service $ns .title)
            "condition" "C" "data" (list $query $threshold)
            "noDataState" "OK" "execErrState" "Error" "for" .for
            "labels" $labels "annotations" $annotations) -}}
    {{- end -}}
    {{- $file := dict "apiVersion" 1 "groups" (list (dict "orgId" 1
          "name" (printf "blackbox-%s-%s" $ns $service)
          "folder" ($alerts.folder | default $team)
          "interval" ($alerts.interval | default "1m")
          "rules" $grafanaRules)) -}}
    {{- $name := printf "%s-%s-blackbox-alerts" $ctx.Release.Name $ctx.Chart.Name -}}
    {{- if gt (len $name) 63 -}}
      {{- fail (printf "blackbox: alerts ConfigMap name %q is longer than 63 characters" $name) -}}
    {{- end }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
  labels:
    mapcolonies.io/grafana-alerts: "true"
data:
  {{ printf "blackbox-%s-%s.yaml" $ns $service }}: |
    {{- toYaml $file | nindent 4 }}
  {{- end -}}
{{- end -}}
{{- end }}
