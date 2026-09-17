{{/*
Parse a byte size to bytes (float). Accepts Kubernetes quantities (6Gi, 512M) and
Loki/go-humanize sizes (4GB, 4GiB). Decimal suffixes (K/KB, M/MB, G/GB) are powers of
1000, binary ones (Ki/KiB, Mi/MiB, Gi/GiB) powers of 1024 — so "4300MB" is ~4.0GiB.
*/}}
{{- define "loki-wrapper.parseBytes" -}}
{{- $raw := toString . | trim -}}
{{- $parts := regexFindAll "^([0-9]+(?:\\.[0-9]+)?)\\s*([A-Za-z]*)$" $raw -1 -}}
{{- if not $parts -}}
{{- fail (printf "loki: cannot parse byte size %q" $raw) -}}
{{- end -}}
{{- $num := regexReplaceAll "^([0-9.]+).*$" $raw "${1}" | float64 -}}
{{- $unit := regexReplaceAll "^[0-9.]+\\s*" $raw "" | lower | trimSuffix "b" -}}
{{- $multipliers := dict
  "" 1.0
  "k" 1e3 "m" 1e6 "g" 1e9 "t" 1e12
  "ki" 1024.0 "mi" 1048576.0 "gi" 1073741824.0 "ti" 1099511627776.0
-}}
{{- if not (hasKey $multipliers $unit) -}}
{{- fail (printf "loki: unsupported byte size unit in %q" $raw) -}}
{{- end -}}
{{- mulf $num (get $multipliers $unit) -}}
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
{{- $maxRatio := required "walReplayCeilingMaxRatio must be set" .Values.walReplayCeilingMaxRatio | float64 -}}
{{- $ratio := divf (include "loki-wrapper.parseBytes" $ceiling | float64) (include "loki-wrapper.parseBytes" $limit | float64) -}}
{{- if gt $ratio $maxRatio -}}
{{- fail (printf "loki: wal.replay_memory_ceiling %v is %.1f%% of write memory limit %v, max allowed is %.1f%% (walReplayCeilingMaxRatio)" $ceiling (mulf $ratio 100) $limit (mulf $maxRatio 100)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
