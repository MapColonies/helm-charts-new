{{/*
Bytes in a Kubernetes memory quantity ("1Gi", "512Mi", "1G", "1073741824").
*/}}
{{- define "alloy-wrapper.bytes" -}}
{{- $q := toString . }}
{{- if not (regexMatch "^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$" $q) }}
{{- fail (printf "%q is not a memory quantity like 1Gi, 512Mi or 1G" $q) }}
{{- end }}
{{- $number := regexFind "^[0-9]+(\\.[0-9]+)?" $q }}
{{- $unit := dict "" 1 "k" 1000 "M" 1000000 "G" 1000000000 "T" 1000000000000 "P" 1000000000000000 "E" 1000000000000000000 "Ki" 1024 "Mi" 1048576 "Gi" 1073741824 "Ti" 1099511627776 "Pi" 1125899906842624 "Ei" 1152921504606846976 }}
{{- mulf (float64 $number) (get $unit (trimPrefix $number $q)) | int64 -}}
{{- end }}

{{/*
Batches the exporter may queue in one pod: exporter.sending_queue.memory_share of the pod's memory
limit, over the size of a full batch (batching.send_batch_max_size records of
exporter.sending_queue.bytes_per_record each). A full queue drops new data instead of growing
until the pod is OOM-killed. exporter.sending_queue.queue_size, when set, is used as is; without
a memory limit there is nothing to size it by, so it stays at 2000.
Takes (dict "root" $ "values" <the workload's subchart `alloy` values>).
*/}}
{{- define "alloy-wrapper.queueSize" -}}
{{- $queue := .root.Values.exporter.sending_queue }}
{{- $limit := dig "resources" "limits" "memory" "" .values }}
{{- if $queue.queue_size }}
{{- $queue.queue_size }}
{{- else if $limit }}
{{- $budget := mulf (include "alloy-wrapper.bytes" $limit) $queue.memory_share }}
{{- $batch := mulf (.root.Values.batching.send_batch_max_size | default 4096) $queue.bytes_per_record }}
{{- max 1 (divf $budget $batch | floor | int64) }}
{{- else }}
{{- 2000 }}
{{- end }}
{{- end }}
