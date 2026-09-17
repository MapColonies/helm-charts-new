{{/*
Parse "<int>MB" / "<int>Mi" to an MB count; Mi treated as MB.
*/}}
{{- define "loki-wrapper.toMB" -}}
{{- $raw := toString . | trim -}}
{{- if not (regexMatch "^[0-9]+(MB|Mi)$" $raw) -}}
{{- fail (printf "loki: %q must be in MB (e.g. 4300MB) or Mi (e.g. 6144Mi)" $raw) -}}
{{- end -}}
{{- regexReplaceAll "(MB|Mi)$" $raw "" -}}
{{- end -}}

{{/*
Fail rendering when the write pod's WAL replay_memory_ceiling exceeds
walReplayCeilingMaxRatio of its memory limit; replay above that OOM-loops a crashed pod.
Skipped when write.resources.limits.memory is unset.
*/}}
{{- define "loki-wrapper.validateWalReplayCeilingMB" -}}
{{- $limit := dig "write" "resources" "limits" "memory" "" .Values.loki -}}
{{- if $limit -}}
{{- $ceiling := dig "loki" "ingester" "wal" "replay_memory_ceiling" "" .Values.loki -}}
{{- if not $ceiling -}}
{{- fail "loki: loki.loki.ingester.wal.replay_memory_ceiling must be set when loki.write.resources.limits.memory is set" -}}
{{- end -}}
{{- $ceilingMB := include "loki-wrapper.toMB" $ceiling | float64 -}}
{{- $limitMB := include "loki-wrapper.toMB" $limit | float64 -}}
{{- $maxRatio := required "walReplayCeilingMaxRatio must be set" .Values.walReplayCeilingMaxRatio | float64 -}}
{{- if gt (divf $ceilingMB $limitMB) $maxRatio -}}
{{- fail (printf "loki: wal.replay_memory_ceiling %v exceeds %.0f%% (walReplayCeilingMaxRatio) of write memory limit %v" $ceiling (mulf $maxRatio 100) $limit) -}}
{{- end -}}
{{- end -}}
{{- end -}}
