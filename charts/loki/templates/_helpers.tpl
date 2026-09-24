{{/*
Parse a Loki byte size ("<int>MB" / "<int>GB", any case) to MiB. Loki's flagext.ByteSize
treats MB/GB as binary (4300MB = 4300MiB) and rejects Mi/Gi, so only MB/GB are allowed here.
*/}}
{{- define "loki-wrapper.lokiSizeToMi" -}}
{{- $raw := toString . | trim | upper -}}
{{- if not (regexMatch "^[0-9]+(MB|GB)$" $raw) -}}
{{- fail (printf "loki: %q must be in MB or GB (e.g. 4300MB)" (toString .)) -}}
{{- end -}}
{{- if hasSuffix "GB" $raw -}}
{{- mul (trimSuffix "GB" $raw | int64) 1024 -}}
{{- else -}}
{{- trimSuffix "MB" $raw -}}
{{- end -}}
{{- end -}}

{{/*
Parse a Kubernetes memory quantity ("<int>Mi" / "<int>Gi") to MiB.
*/}}
{{- define "loki-wrapper.k8sMemoryToMi" -}}
{{- $raw := toString . | trim -}}
{{- if not (regexMatch "^[0-9]+(Mi|Gi)$" $raw) -}}
{{- fail (printf "loki: %q must be in Mi or Gi (e.g. 6144Mi)" $raw) -}}
{{- end -}}
{{- if hasSuffix "Gi" $raw -}}
{{- mul (trimSuffix "Gi" $raw | int64) 1024 -}}
{{- else -}}
{{- trimSuffix "Mi" $raw -}}
{{- end -}}
{{- end -}}

{{/*
Fail rendering when the write pod's WAL replay_memory_ceiling exceeds
walReplayCeilingMaxRatio of its memory limit; replay above that OOM-loops a crashed pod.
Skipped when write.resources.limits.memory is unset.
*/}}
{{- define "loki-wrapper.validateWalReplayCeiling" -}}
{{- $limit := dig "write" "resources" "limits" "memory" "" .Values.loki -}}
{{- if $limit -}}
{{- $ceiling := dig "loki" "ingester" "wal" "replay_memory_ceiling" "" .Values.loki -}}
{{- if not $ceiling -}}
{{- fail "loki: loki.loki.ingester.wal.replay_memory_ceiling must be set when loki.write.resources.limits.memory is set" -}}
{{- end -}}
{{- $ceilingMi := include "loki-wrapper.lokiSizeToMi" $ceiling | float64 -}}
{{- $limitMi := include "loki-wrapper.k8sMemoryToMi" $limit | float64 -}}
{{- $maxRatio := required "walReplayCeilingMaxRatio must be set" .Values.walReplayCeilingMaxRatio | float64 -}}
{{- if gt (round (divf $ceilingMi $limitMi) 6) $maxRatio -}}
{{- fail (printf "loki: wal.replay_memory_ceiling %v exceeds %.0f%% (walReplayCeilingMaxRatio) of write memory limit %v" $ceiling (mulf $maxRatio 100) $limit) -}}
{{- end -}}
{{- end -}}
{{- end -}}
