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
a memory limit there is nothing to size it by, so it stays at 2000. The pod is the alloy Deployment's.
*/}}
{{- define "alloy-wrapper.queueSize" -}}
{{- $queue := .Values.exporter.sending_queue }}
{{- $limit := dig "resources" "limits" "memory" "" .Values.alloy.alloy }}
{{- if $queue.queue_size }}
{{- $queue.queue_size }}
{{- else if $limit }}
{{- $budget := mulf (include "alloy-wrapper.bytes" $limit) $queue.memory_share }}
{{- $batch := mulf (.Values.batching.send_batch_max_size | default 4096) $queue.bytes_per_record }}
{{- max 1 (divf $budget $batch | floor | int64) }}
{{- else }}
{{- 2000 }}
{{- end }}
{{- end }}

{{/*
The alloy Deployment's `loki-push` port (alloy.alloy.extraPorts), where it receives the pod logs.
Returns the port entry as YAML.
*/}}
{{- define "alloy-wrapper.podLogsPortEntry" -}}
{{- $entry := dict }}
{{- range .Values.alloy.alloy.extraPorts }}
{{- if eq .name "loki-push" }}{{ $entry = . }}{{ end }}
{{- end }}
{{- if not $entry }}
{{- fail "alloy.alloy.extraPorts must have a `loki-push` port, where the alloy Deployment receives the pod logs" }}
{{- end }}
{{- toYaml $entry }}
{{- end }}

{{/*
The port the alloy Deployment listens on for the pod logs.
*/}}
{{- define "alloy-wrapper.podLogsPort" -}}
{{- (include "alloy-wrapper.podLogsPortEntry" . | fromYaml).targetPort -}}
{{- end }}

{{/*
The alloy-logs StatefulSet's name, from the alloy chart's own helper, so it follows the release name and
alloy-logs.fullnameOverride.
*/}}
{{- define "alloy-wrapper.podLogsStatefulSet" -}}
{{- include "alloy.fullname" (dict "Values" (index .Values "alloy-logs") "Chart" (dict "Name" "alloy-logs") "Release" .Release) -}}
{{- end }}

{{/*
Where the alloy-logs StatefulSet sends the pod logs: the alloy Deployment's Service, named by the alloy chart's
own helper so it follows the release name and fullnameOverride.
*/}}
{{- define "alloy-wrapper.podLogsUrl" -}}
{{- $service := include "alloy.fullname" (dict "Values" .Values.alloy "Chart" (dict "Name" "alloy") "Release" .Release) }}
{{- printf "http://%s:%v/loki/api/v1/push" $service (include "alloy-wrapper.podLogsPortEntry" . | fromYaml).port -}}
{{- end }}

{{/*
The registries and pull secrets a workload's pods pull with, as the alloy chart picks them: global.image (from
the top-level global or that workload's own), else the workload's own image settings.
Takes the workload's values (.Values.alloy or .Values.alloy-logs).
*/}}
{{- define "alloy-wrapper.imageSources" -}}
{{- $global := dig "global" "image" dict . }}
{{- toYaml (dict
  "alloy" ($global.registry | default (dig "image" "registry" "" .))
  "configReloader" ($global.registry | default (dig "configReloader" "image" "registry" "" .))
  "pullSecrets" ($global.pullSecrets | default (dig "image" "pullSecrets" list .))) }}
{{- end }}

{{/*
Fails the render when the two workloads would pull from different registries or with different pull secrets.
The alloy-logs StatefulSet doesn't inherit alloy.* values, so a registry set only under alloy.global.image
would leave it pulling from docker.io and quay.io.
*/}}
{{- define "alloy-wrapper.validateImages" -}}
{{- $deployment := include "alloy-wrapper.imageSources" .Values.alloy }}
{{- $statefulset := include "alloy-wrapper.imageSources" (index .Values "alloy-logs") }}
{{- if ne $deployment $statefulset }}
{{- fail (printf "alloy-logs would pull its images from other registries than alloy:\n  alloy:\n%s\n  alloy-logs:\n%s\nSet the registry and pull secrets under the top-level global.image, which both use, instead of alloy.global.image." ($deployment | indent 4) ($statefulset | indent 4)) }}
{{- end }}
{{- end }}
