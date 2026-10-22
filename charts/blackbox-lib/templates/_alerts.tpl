{{/*
Grafana alert rules for the app's Blackbox probes, as a ConfigMap that Grafana's alerts sidecar loads (label
mapcolonies.io/grafana-alerts). Rendered only when blackbox.enabled and blackbox.alerts.enabled are true.
The rules select the probe metrics by the Service's name and namespace, the labels the blackbox-services
scrape job puts on them, so the Service name has to be passed in.

Usage, in templates/monitoring.yaml:
  {{- include "blackbox-lib.grafanaAlertsConfigMap" (dict "ctx" . "service" (include "my-chart.fullname" .)) }}
*/}}
{{/*
A number above 0, printed. Also accepts numeric strings: helm --set passes decimals such as 0.5 as strings.
Usage: include "blackbox-lib.positiveNumber" (dict "value" $v "key" "latency.maxSeconds") | float64
*/}}
{{- define "blackbox-lib.positiveNumber" -}}
{{- $v := .value -}}
{{- if and (kindIs "string" $v) (regexMatch "^[0-9]+(\\.[0-9]+)?$" $v) -}}
  {{- $v = float64 $v -}}
{{- end -}}
{{- if not (and (or (kindIs "float64" $v) (kindIs "int64" $v) (kindIs "int" $v)) (gt (float64 $v) 0.0)) -}}
  {{- fail (printf "blackbox.alerts.rules.%s must be a number above 0, got %v" .key $v) -}}
{{- end -}}
{{- $v -}}
{{- end }}

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
  {{- $extraLabels := $alerts.extraLabels | default dict -}}
  {{- $extraAnnotations := $alerts.extraAnnotations | default dict -}}
  {{- range $key := list "service" "namespace" "alert_team" "severity" -}}
    {{- if hasKey $extraLabels $key -}}
      {{- fail (printf "blackbox.alerts.extraLabels.%s is reserved: the alert sets it itself" $key) -}}
    {{- end -}}
  {{- end -}}
  {{- $datasource := $alerts.datasourceUid | default "prometheus" -}}
  {{- $selector := printf "{job=\"blackbox-services\",namespace=%q,service=%q}" $ns $service -}}
  {{- $rules := $alerts.rules | default dict -}}
  {{- /* Rule UIDs are deterministic, so a disabled rule can be deleted by UID: Grafana keeps provisioned rules
         that only disappear from the file. */ -}}
  {{- $uid := dict -}}
  {{- range $rule := list "availability" "latency" "ssl-expiry" -}}
    {{- $_ := set $uid $rule (printf "bb-%s" (sha256sum (printf "%s/%s/%s" $ns $service $rule) | trunc 37)) -}}
  {{- end -}}
  {{- $out := list -}}
  {{- $deletes := list -}}

  {{- /* availability: on unless rules.availability.enabled is false. "or up" also fires when the probe cannot run
         at all (exporter down or unreachable): then there is no probe_success, only up == 0. */ -}}
  {{- $r := $rules.availability | default dict -}}
  {{- if or (not (hasKey $r "enabled")) $r.enabled -}}
    {{- $out = append $out (dict "rule" "availability" "title" "is down" "for" ($r.downDuration | default "1m") "forKey" "downDuration"
          "severity" ($r.severity | default "critical") "expr" (printf "probe_success%s or up%s" $selector $selector) "op" "lt" "threshold" 1
          "summary" (printf "%s is down" $service)
          "description" (printf "The Blackbox probe of {{ $labels.instance }} (service %s in namespace %s) is failing." $service $ns)) -}}
  {{- else -}}
    {{- $deletes = append $deletes (dict "orgId" 1 "uid" (get $uid "availability")) -}}
  {{- end -}}

  {{- /* latency: only when rules.latency.enabled. Not while the probe fails: a failing probe usually times out,
         and that is already the availability alert. */ -}}
  {{- $r = $rules.latency | default dict -}}
  {{- if $r.enabled -}}
    {{- $max := include "blackbox-lib.positiveNumber" (dict "value" ($r.maxSeconds | default 1) "key" "latency.maxSeconds") | float64 -}}
    {{- $out = append $out (dict "rule" "latency" "title" "is slow" "for" ($r.forDuration | default "5m") "forKey" "latency.forDuration"
          "severity" ($r.severity | default "warning")
          "expr" (printf "probe_duration_seconds%s unless probe_success%s == 0" $selector $selector) "op" "gt" "threshold" $max
          "summary" (printf "%s responds slowly" $service)
          "description" (printf "The Blackbox probe of {{ $labels.instance }} (service %s in namespace %s) takes longer than %vs." $service $ns $max)) -}}
  {{- else -}}
    {{- $deletes = append $deletes (dict "orgId" 1 "uid" (get $uid "latency")) -}}
  {{- end -}}

  {{- /* sslExpiry: only when rules.sslExpiry.enabled */ -}}
  {{- $r = $rules.sslExpiry | default dict -}}
  {{- if $r.enabled -}}
    {{- $days := include "blackbox-lib.positiveNumber" (dict "value" ($r.warningDays | default 21) "key" "sslExpiry.warningDays") | float64 -}}
    {{- $out = append $out (dict "rule" "ssl-expiry" "title" "certificate expires soon" "for" ($r.forDuration | default "1h") "forKey" "sslExpiry.forDuration"
          "severity" ($r.severity | default "warning") "expr" (printf "(probe_ssl_earliest_cert_expiry%s - time()) / 86400" $selector) "op" "lt" "threshold" $days
          "summary" (printf "The certificate of %s expires soon" $service)
          "description" (printf "The TLS certificate of {{ $labels.instance }} (service %s in namespace %s) expires in less than %v days." $service $ns $days)) -}}
  {{- else -}}
    {{- $deletes = append $deletes (dict "orgId" 1 "uid" (get $uid "ssl-expiry")) -}}
  {{- end -}}

  {{- if $out -}}
    {{- if not $team -}}
      {{- fail "blackbox.alerts.team is unknown: set mclabels.owner (or blackbox.alerts.team) so the alerts can be routed" -}}
    {{- end -}}
    {{- if not (regexMatch "^[a-z0-9-]+$" $team) -}}
      {{- fail (printf "blackbox.alerts.team must be lowercase letters, digits and \"-\", got %q" $team) -}}
    {{- end -}}
  {{- end -}}
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
            "uid" (get $uid .rule)
            "title" (printf "%s (%s) %s" $service $ns .title)
            "condition" "C" "data" (list $query $threshold)
            "noDataState" "OK" "execErrState" "Error" "for" .for
            "labels" $labels "annotations" $annotations) -}}
    {{- end -}}
  {{- /* A file with only deleteRules is still rendered, so turning rules off removes them from Grafana. */ -}}
  {{- if or $grafanaRules $deletes -}}
    {{- $file := dict "apiVersion" 1 -}}
    {{- if $grafanaRules -}}
      {{- $_ := set $file "groups" (list (dict "orgId" 1
            "name" (printf "blackbox-%s-%s" $ns $service)
            "folder" ($alerts.folder | default $team)
            "interval" ($alerts.interval | default "1m")
            "rules" $grafanaRules)) -}}
    {{- end -}}
    {{- if $deletes -}}
      {{- $_ := set $file "deleteRules" $deletes -}}
    {{- end -}}
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
