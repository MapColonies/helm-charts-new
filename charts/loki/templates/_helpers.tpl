{{/*
Parse "<number>GB" / "<number>Gi" to a GB count; Gi treated as GB.
*/}}
{{- define "loki-wrapper.toGB" -}}
{{- $raw := toString . | trim -}}
{{- if not (regexMatch "^[0-9]+(\\.[0-9]+)?(GB|Gi)$" $raw) -}}
{{- fail (printf "loki: %q must be in GB (e.g. 4.2GB) or Gi (e.g. 6Gi)" $raw) -}}
{{- end -}}
{{- regexReplaceAll "(GB|Gi)$" $raw "" -}}
{{- end -}}

{{/*
Fail rendering when the write pod's WAL replay_memory_ceiling exceeds
walReplayCeilingMaxRatio of its memory limit; replay above that OOM-loops a crashed pod.
Skipped when write.resources.limits.memory is unset.
*/}}
{{- define "loki-wrapper.validateWalReplayCeilingGB" -}}
{{- $limit := dig "write" "resources" "limits" "memory" "" .Values.loki -}}
{{- if $limit -}}
{{- $ceiling := dig "loki" "ingester" "wal" "replay_memory_ceiling" "" .Values.loki -}}
{{- if not $ceiling -}}
{{- fail "loki: loki.loki.ingester.wal.replay_memory_ceiling must be set when loki.write.resources.limits.memory is set" -}}
{{- end -}}
{{- $ceilingGB := include "loki-wrapper.toGB" $ceiling | float64 -}}
{{- $limitGB := include "loki-wrapper.toGB" $limit | float64 -}}
{{- $maxRatio := required "walReplayCeilingMaxRatio must be set" .Values.walReplayCeilingMaxRatio | float64 -}}
{{- /* rounded so an exact ratio like 4.2/6 (0.7000000000000001) passes */ -}}
{{- if gt (round (divf $ceilingGB $limitGB) 6) $maxRatio -}}
{{- fail (printf "loki: wal.replay_memory_ceiling %v exceeds %.0f%% (walReplayCeilingMaxRatio) of write memory limit %v" $ceiling (mulf $maxRatio 100) $limit) -}}
{{- end -}}
{{- end -}}
{{- end -}}
