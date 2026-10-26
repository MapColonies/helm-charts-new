{{/*
The export end of both Alloy configs: health filter -> batch -> OTLP/HTTP exporter, and Alloy's own traces.
Takes (dict "root" $ "values" <the workload's subchart `alloy` values>), which size the exporter queue.
*/}}
{{- define "alloy-wrapper.config.export" -}}
{{- $root := .root -}}
otelcol.processor.filter "health_filter" {
    error_mode = "ignore"
    logs {
        log_record = [
        `attributes["url.path"] == "/health"`,
        `attributes["url.path"] == "/liveness"`,
        `attributes["url.path"] == "/metrics"`,
        ]
    }

    output {
        logs = [otelcol.processor.batch.default.input]
    }
}

otelcol.processor.batch "default" {
    timeout = {{ $root.Values.batching.timeout | default "5s" | quote }}
    send_batch_size = {{ $root.Values.batching.send_batch_size | default 2048 }}
    send_batch_max_size = {{ $root.Values.batching.send_batch_max_size | default 4096 }}

    output {
        logs = [otelcol.exporter.otlphttp.default.input]
        traces = [otelcol.exporter.otlphttp.default.input]
    }
}

otelcol.exporter.otlphttp "default" {
    client {
        endpoint = {{ $root.Values.exporter.endpoint | default "http://infra-loki-gateway/otlp" | quote }}
    }
    sending_queue {
        enabled      = true
        num_consumers = {{ $root.Values.exporter.sending_queue.num_consumers | default 4 }}
        // Sized to the pod's memory limit; when full, new batches are dropped instead of blocking
        queue_size   = {{ include "alloy-wrapper.queueSize" . }}
        block_on_overflow = false
    }
    retry_on_failure {
        enabled         = true
        initial_interval = {{ $root.Values.exporter.retry_on_failure.initial_interval | default "10s" | quote }}
        max_interval    = {{ $root.Values.exporter.retry_on_failure.max_interval | default "30s" | quote }}
        max_elapsed_time = {{ $root.Values.exporter.retry_on_failure.max_elapsed_time | default "60s" | quote }}
    }
}

tracing {
    sampling_fraction = 0.1
    write_to          = [otelcol.processor.batch.alloy_traces.input]
}

otelcol.processor.batch "alloy_traces" {
    timeout         = "5s"
    send_batch_size = 1024

    output {
        traces = [otelcol.exporter.otlp.tempo.input]
    }
}

otelcol.exporter.otlp "tempo" {
    client {
        endpoint = "infra-otel.{{ $root.Values.namespaces | first }}.svc.cluster.local:4317"

        tls {
            insecure = true
        }
    }
}
{{- end }}
