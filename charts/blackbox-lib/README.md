# blackbox-lib

Library chart for self-service Blackbox probing. It turns a `blackbox:` block in an application's
`values.yaml` into Prometheus probe annotations on the application's own `Service`. The central
Prometheus job `blackbox-services` (see `charts/prometheus`) discovers annotated Services and probes
them through the Blackbox exporter.

A library chart only provides named templates: it renders nothing by itself and cannot be installed.

## Add it to a chart

<!-- x-release-please-start-version -->
```yaml
# Chart.yaml
dependencies:
  - name: blackbox-lib
    version: "0.0.1"
    repository: oci://acrarolibotnonprod.azurecr.io/helm/common
```
<!-- x-release-please-end-version -->

Call the helper in the `metadata` of the chart's own Service template. Use the form that matches the chart.

Chart with `.Values.service.name` and `.Values.service.port`:

```yaml
metadata:
  name: {{ .Values.service.name }}
  annotations:
    {{- include "blackbox-lib.serviceAnnotations" . | nindent 4 }}
```

Chart that computes the Service name and port, such as charts built from `ts-server-boilerplate`:

```yaml
metadata:
  name: {{ include "ts-server-boilerplate.fullname" . }}
  annotations:
    {{- include "blackbox-lib.serviceAnnotations" (dict "ctx" . "name" (include "ts-server-boilerplate.fullname" .) "port" .Values.server.port) | nindent 4 }}
```

Both forms read the `blackbox:` block from the chart's values. With `blackbox.enabled: false` the helper
prints nothing and `annotations:` stays empty.

## Values

| Key | Default | Description |
| --- | --- | --- |
| `blackbox.enabled` | `false` | Add the probe annotations. |
| `blackbox.serviceName` | `""` | Service name for the internal address. Overrides `.Values.service.name` and the `name` argument. |
| `blackbox.servicePort` | `""` | Service port. Overrides `.Values.service.port` and the `port` argument. |
| `blackbox.target.host` | `""` | Empty: probe `<service>.<namespace>.svc:<port>`. Set: probe this host, for example the OpenShift Route host. No port is added. |
| `blackbox.target.scheme` | `""` | `http` or `https`. Empty: `https` when `target.host` is set, otherwise `http`. |
| `blackbox.target.path` | `/liveness` | Path to probe. Must start with `/`. |
| `blackbox.target.port` | `""` | Port for the internal address. Empty: the Service port. |
| `blackbox.customExporter.enabled` | `false` | Probe through the chart's own exporter (`blackbox-exporter` subchart) instead of the central one. |
| `blackbox.customExporter.moduleName` | `""` | Exporter module to use. Required when `customExporter.enabled` is true. |
| `blackbox.customExporter.port` | `9115` | Port of the custom exporter Service. |
| `blackbox.customExporter.fullnameOverride` | `""` | Name of the custom exporter Service. Empty: `<release>-<chart>-blackbox`, or `<release>-blackbox` when the release name contains the chart name. |
| `blackbox.alerts.enabled` | `false` | Reserved for the Grafana alert rules. |

Example, internal probe of `/liveness` through the central exporter:

```yaml
blackbox:
  enabled: true
```

Example, external probe through the Route:

```yaml
blackbox:
  enabled: true
  target:
    host: my-service.apps.example.com
    path: /api/v1/health
```

Invalid values fail the render with a message that names the key, for example
`blackbox.target.path must start with "/", got "liveness"`.

## Annotations

| Annotation | Value |
| --- | --- |
| `prometheus.io/probe` | `"true"` |
| `prometheus.io/probe-host` | `target.host`, or `<service>.<namespace>.svc:<port>` |
| `prometheus.io/probe-scheme` | `http` or `https` |
| `prometheus.io/probe-path` | `target.path` |
| `prometheus.io/probe-exporter` | `<exporter name>.<namespace>.svc:<customExporter.port>`, only with `customExporter.enabled`. The exporter name includes the app chart name, so several apps in one umbrella release each get their own exporter. |
| `prometheus.io/probe-module` | `customExporter.moduleName`, only with `customExporter.enabled` |

The probe is `GET <exporter>/probe?module=<module>&target=<scheme>://<probe-host><probe-path>`, and its
metrics carry the `service` and `namespace` labels of the annotated Service.

## Wrapper charts

Charts that wrap an upstream chart (for example `charts/loki` and `charts/grafana`) do not template the
Service themselves, and a values file cannot call a template. Put the annotations into the upstream chart's
service annotations value instead. Prometheus only reads the annotations; it does not matter how they were set.

1. Render the annotation set once with the helper, from any chart that depends on `blackbox-lib`
   (here the test consumer in this repository):

   ```bash
   make -C charts/blackbox-lib deps
   helm template x charts/blackbox-lib/tests/consumers/spec -n infra-dev --show-only templates/service.yaml \
     --set blackbox.enabled=true \
     --set blackbox.serviceName=infra-loki-gateway \
     --set blackbox.servicePort=80 \
     --set blackbox.target.path=/
   ```

2. Copy the `annotations` into the upstream value:

   ```yaml
   loki:
     gateway:
       service:
         annotations:
           prometheus.io/probe: "true"
           prometheus.io/probe-host: "infra-loki-gateway.infra-dev.svc:80"
           prometheus.io/probe-scheme: "http"
           prometheus.io/probe-path: "/"
   ```

   Update the copy when the target changes, for example when the Service moves to another namespace.

Tested keys (rendered with the real dev values; only the annotations of that Service change):

| Wrapper chart | Value key | Service |
| --- | --- | --- |
| `charts/loki` | `loki.gateway.service.annotations` | `infra-loki-gateway` |
| `charts/grafana` | `grafana.service.annotations` | `infra-grafana` |

For other wrapper charts, check the upstream chart's `values.yaml` for its service annotations key; it is not
the same in every chart.

## Tests

```bash
make -C charts/blackbox-lib test     # render the test consumers and compare with tests/expected
make -C charts/blackbox-lib update   # rewrite tests/expected after an intended change; review the diff
```

- `tests/consumers/spec`: a minimal chart that uses `.Values.service.*`.
- `tests/consumers/boilerplate`: a copy of `ts-server-boilerplate/helm` that uses the explicit form.
  `mclabels` is replaced by a stub because its registry is not reachable from PR checks.
- `tests/cases/<consumer>/*.yaml`: values for each case; the rendered Service must match `tests/expected`.
- `tests/failures/<consumer>/*.yaml`: invalid values; rendering must fail with the error in the first line
  (`# expect-error: <regex>`).

The chart has no `ci/` directory because a library chart cannot be rendered on its own.
