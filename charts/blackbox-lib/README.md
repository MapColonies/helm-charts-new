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

Call the helper in the `metadata` of the chart's own Service template:

```yaml
metadata:
  name: {{ include "my-chart.fullname" . }}
  annotations:
    {{- include "blackbox-lib.serviceAnnotations" . | nindent 4 }}
```

It reads the `blackbox:` block from the chart's values. With `blackbox.enabled: false` it prints nothing and
`annotations:` stays empty. The helper needs neither the Service name nor its port: Prometheus discovers the
Service's address itself.

## Values

| Key | Default | Description |
| --- | --- | --- |
| `blackbox.enabled` | `false` | Add the probe annotations. |
| `blackbox.module` | `""` | Probe module. Empty: `http_2xx` on the central exporter. On the central exporter only allowlisted modules are used (today `http_2xx`); others fall back to `http_2xx`. Required with `customExporter.enabled`: the name of the module the `blackbox-exporter` subchart generates. Letters, digits, `_` and `-`. |
| `blackbox.target.host` | `""` | Empty: probe the Service's own address `<service>.<namespace>.svc:<port>`. Set: probe this host, for example the OpenShift Route host. No port is added. |
| `blackbox.target.scheme` | `""` | `http` or `https`. Empty: `https` when `target.host` is set, otherwise `http`. |
| `blackbox.target.path` | `/liveness` | Path to probe. Must start with `/`. |
| `blackbox.target.port` | `""` | Port number to probe on a multi-port Service. Empty: every port of the Service is probed. |
| `blackbox.customExporter.enabled` | `false` | Probe through the chart's own exporter (`blackbox-exporter` subchart) instead of the central one. |
| `blackbox.customExporter.port` | `9115` | Port of the custom exporter Service. |
| `blackbox.customExporter.fullnameOverride` | `""` | Name of the custom exporter Service. Empty: `<release>-<chart>-blackbox`. Names longer than 63 characters fail the render instead of being cut, so two apps can never end up with the same name; set an override then. |
| `blackbox.alerts.enabled` | `false` | Reserved for the Grafana alert rules. |

Example, probe `/liveness` on the Service through the central exporter:

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
| `prometheus.io/probe-host` | `target.host`, only when set |
| `prometheus.io/probe-scheme` | `http` or `https` |
| `prometheus.io/probe-path` | `target.path` |
| `prometheus.io/probe-port` | `target.port`, only when set |
| `prometheus.io/probe-module` | `module`, only when set |
| `prometheus.io/probe-exporter` | `<exporter name>.<namespace>.svc:<customExporter.port>`, only with `customExporter.enabled`. The exporter name includes the app chart name, so several apps in one umbrella release each get their own exporter. |

The probe is `GET <exporter>/probe?module=<module>&target=<scheme>://<host><probe-path>`, where `<host>` is
`probe-host` or the Service's discovered `<service>.<namespace>.svc:<port>`. Its metrics carry the `service` and
`namespace` labels of the annotated Service.

## Wrapper charts

Charts that wrap an upstream chart (for example `charts/loki` and `charts/grafana`) do not template the
Service themselves, and a values file cannot call a template. Put the annotations into the upstream chart's
service annotations value instead. Prometheus only reads the annotations; it does not matter how they were set.
Since the Service address is discovered, the annotations do not depend on the Service name or namespace:

```yaml
loki:
  gateway:
    service:
      annotations:
        prometheus.io/probe: "true"
        prometheus.io/probe-scheme: "http"
        prometheus.io/probe-path: "/"
```

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

- `tests/consumers/spec`: a minimal chart with its own Service template.
- `tests/consumers/boilerplate`: a copy of `ts-server-boilerplate/helm` with the helper in `templates/service.yaml`.
  `mclabels` is replaced by a stub because its registry is not reachable from PR checks.
- `tests/cases/<consumer>/*.yaml`: values for each case; the rendered Service must match `tests/expected`.
- `tests/failures/<consumer>/*.yaml`: invalid values; rendering must fail with the error in the first line
  (`# expect-error: <regex>`).

The chart has no `ci/` directory because a library chart cannot be rendered on its own.
