{{/*
Parse "<int>Mi" to a MiB count. Mi only: it is the one unit both k8s quantities and
Loki's byte parser accept, so the ratio below compares like with like.
*/}}
{{- define "loki-wrapper.toMi" -}}
{{- $raw := toString . | trim -}}
{{- if not (regexMatch "^[0-9]+Mi$" $raw) -}}
{{- fail (printf "loki: %q must be in Mi (e.g. 4300Mi)" $raw) -}}
{{- end -}}
{{- trimSuffix "Mi" $raw -}}
{{- end -}}

{{/*
Fail rendering when the write pod's WAL replay_memory_ceiling exceeds
walReplayCeilingMaxRatio of its memory limit; replay above that OOM-loops a crashed pod.
Skipped when write.resources.limits.memory is unset.
*/}}
{{- define "loki-wrapper.validateWalReplayCeilingMi" -}}
{{- $limit := dig "write" "resources" "limits" "memory" "" .Values.loki -}}
{{- if $limit -}}
{{- $ceiling := dig "loki" "ingester" "wal" "replay_memory_ceiling" "" .Values.loki -}}
{{- if not $ceiling -}}
{{- fail "loki: loki.loki.ingester.wal.replay_memory_ceiling must be set when loki.write.resources.limits.memory is set" -}}
{{- end -}}
{{- $ceilingMi := include "loki-wrapper.toMi" $ceiling | float64 -}}
{{- $limitMi := include "loki-wrapper.toMi" $limit | float64 -}}
{{- $maxRatio := required "walReplayCeilingMaxRatio must be set" .Values.walReplayCeilingMaxRatio | float64 -}}
{{- if gt (round (divf $ceilingMi $limitMi) 6) $maxRatio -}}
{{- fail (printf "loki: wal.replay_memory_ceiling %v exceeds %.0f%% (walReplayCeilingMaxRatio) of write memory limit %v" $ceiling (mulf $maxRatio 100) $limit) -}}
{{- end -}}
{{- end -}}
{{- end -}}
