# blackbox-exporter

Team-local [Blackbox exporter](https://github.com/prometheus/blackbox_exporter) for probes that need more than
"HTTP 2xx": specific status codes, a response body regex, or request headers. It deploys one exporter in the
team's namespace with one probe module generated from values, so teams never write Blackbox configuration.

Use it together with `blackbox-lib`: when `blackbox.customExporter.enabled` is true, `blackbox-lib` adds
`prometheus.io/probe-exporter` and `prometheus.io/probe-module` to the application's Service, and the central
Prometheus sends the probe through this exporter instead of the central one.

## Add it to a chart

Declare it with `alias: blackbox`, so it reads the same `blackbox:` block as `blackbox-lib`, and with the
`condition`, so nothing is deployed unless the custom exporter is enabled:

<!-- x-release-please-start-version -->
```yaml
# Chart.yaml
dependencies:
  - name: blackbox-exporter
    version: "0.0.1"
    repository: oci://acrarolibotnonprod.azurecr.io/helm/common
    alias: blackbox
    condition: blackbox.customExporter.enabled
```
<!-- x-release-please-end-version -->

Without the alias the subchart cannot see `blackbox.customExporter`.

```yaml
# values.yaml
blackbox:
  enabled: true
  module: payment_json_validation
  customExporter:
    enabled: true
    rules:
      validStatusCodes: [200, 202]
      bodyRegexMatch:
        - '"status":\s*"HEALTHY"'
      headers:
        X-Probe-Client: blackbox
    podLabels:
      mapcolonies.io/owner: raster   # your domain: vector, raster, 3d, app, dem, infra, common, automation
```

Set `mapcolonies.io/owner` in `podLabels`: the subchart cannot see the chart's own `mclabels:` block, and
gatekeeper rejects the exporter Pod without `mapcolonies.io/owner` and `mapcolonies.io/environment` in enforced
namespaces. `mapcolonies.io/environment` (and `owner`, if set there) is taken from `global.mclabels`, which the
site values set for every release.

This deploys `<release>-<app chart>-blackbox` (Deployment, Service on port 9115, ConfigMap) with this module:

```yaml
modules:
  payment_json_validation:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200, 202]
      fail_if_body_not_matches_regexp: ['"status":\s*"HEALTHY"']
      headers:
        X-Probe-Client: blackbox
      follow_redirects: true
      preferred_ip_protocol: ip4
      valid_http_versions: [HTTP/1.1, HTTP/2.0]
```

When the probe scheme is `https` (`blackbox.target.scheme`, or a `blackbox.target.host` without a scheme), the
module also sets `fail_if_not_ssl: true`. TLS certificates are always verified, and
`probe_ssl_earliest_cert_expiry` is exported.

## Values

All keys are under `blackbox.` in the parent chart.

| Key | Default | Description |
| --- | --- | --- |
| `customExporter.enabled` | `false` | Deploy the exporter. Also the `condition` of the dependency. |
| `module` | `""` | Name of the generated module, shared with `blackbox-lib` (which sets it as `prometheus.io/probe-module`). Required; letters, digits, `_` and `-`. |
| `customExporter.port` | `9115` | Service port. |
| `customExporter.fullnameOverride` | `""` | Resource name instead of `<release>-<app chart>-blackbox`. `blackbox-lib` reads the same key, so the annotation still matches. Names longer than 63 characters fail the render instead of being cut. |
| `customExporter.timeout` | `5s` | Probe timeout, a duration such as `5s`, `500ms` or `1m30s`. Keep it below the Prometheus scrape timeout (10s). |
| `customExporter.rules.validStatusCodes` | `[]` | Accepted status codes, as numbers. Empty: any 2xx. |
| `customExporter.rules.bodyRegexMatch` | `[]` | Regular expressions (Go RE2 syntax, so no lookahead or backreferences) that must all match the body. An invalid one fails the render. |
| `customExporter.rules.headers` | `{}` | Headers sent with the probe. |
| `customExporter.image.registry` | `""` | Empty: `global.cloudProvider.dockerRegistryUrl`, then `global.imageRegistry`. |
| `customExporter.image.repository` | `infra/blackbox-exporter` | |
| `customExporter.image.tag` | `v0.28.0` | Same version as the central exporter. |
| `customExporter.imagePullSecretName` | `""` | Empty: `global.cloudProvider.imagePullSecretName`, then `global.imagePullSecretName`. |
| `customExporter.ca.enabled` | `false` | Trust an extra CA from a Secret, for targets whose certificate is not signed by a public CA. |
| `customExporter.ca.secretName` / `key` | `root-ca` / `ca.crt` | Mounted as `/etc/ssl/certs/blackbox-extra-ca.crt`, next to the system bundle, so public CAs stay trusted. The Secret must exist in the team's namespace. |
| `customExporter.resources` | 25m/100m CPU, 64Mi | CPU limit is 4x the request, as gatekeeper requires. |
| `customExporter.podLabels` | `{}` | Extra Pod labels. Set `mapcolonies.io/owner` here (see the example above). |

Invalid values fail the render with a message that names the key.

**Headers are stored in plain text in a ConfigMap. Never put secrets (API keys, tokens) in `rules.headers`.**

## Pod

- Runs under OpenShift's `restricted` SCC: no fixed UID, non-root, no privilege escalation, all capabilities
  dropped, read-only root filesystem.
- Liveness and readiness on `/-/healthy`. The exporter's own metrics are scraped through the
  `prometheus.io/*` Pod annotations.
- The Pod restarts when the generated module changes (`checksum/config` annotation).
- Labels: `mapcolonies.io/component: monitoring`, `mapcolonies.io/part-of: blackbox`, and
  `mapcolonies.io/environment` / `mapcolonies.io/owner` from `global.mclabels` when set.

## Limitations

- One exporter per app chart. Apps in the same umbrella release each get their own, because the name includes the
  app chart name. It is read from the template path (`.Chart.Name` is the alias `blackbox` here) and must match
  the name `blackbox-lib` builds from the app chart's `.Chart.Name`; `make test` checks that the two agree.
- **The same app chart twice in one umbrella, under different aliases** (for example `pycsw` and `pycsw-private`
  in `raster-serving`): Helm 3 renders the nested exporter only for the first copy, so the second copy's
  `prometheus.io/probe-exporter` points to a Service that does not exist (reproduced with Helm 3.19 and 3.20;
  Helm 4.0 renders both). Workaround on Helm 3: keep `customExporter.enabled: false` for the second copy, so it is
  probed through the central exporter.
- HTTP probes only.

## Tests

- `ci/*-values.yaml` must lint and render; `ci/invalid/*-values.yaml` must fail with the message in their
  `# expect-error:` line (checked by the repo's `render-chart.sh`).
- `make -C charts/blackbox-exporter test` (`tests/naming.sh`, needs `helm` and `yq`) renders an umbrella whose apps
  use `blackbox-lib` and this chart, and checks that every `probe-exporter` annotation points to an exporter
  Service serving the annotated module. A PR job runs it when either chart changes.

To check a generated module with the exporter itself:

```bash
helm template t charts/blackbox-exporter -f charts/blackbox-exporter/ci/rules-values.yaml \
  --show-only templates/configmap.yaml | yq '.data["blackbox.yaml"]' > /tmp/blackbox.yaml
blackbox_exporter --config.check --config.file=/tmp/blackbox.yaml
```
