# datasource-library

A Helm library chart for generating Grafana datasource provisioning YAML. Designed for use with the [Grafana k8s-sidecar](https://github.com/kiwigrid/k8s-sidecar): consumer charts create a labeled ConfigMap that the sidecar picks up and writes into Grafana's provisioning directory.

## Usage

Add as a dependency in your chart's `Chart.yaml`:

<!-- x-release-please-start-version -->
```yaml
dependencies:
  - name: datasource-library
    version: "0.1.0"
    repository: "oci://acrarolibotnonprod.azurecr.io/helm/infra"
```
<!-- x-release-please-end-version -->

Create a `templates/datasources.yaml` in your chart:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-datasources
  namespace: {{ .Release.Namespace }}
  labels:
    mapcolonies.io/grafana-datasources: "true"
data:
  postgres.yaml: |
{{ include "datasource-library.postgres" . | indent 4 }}
```

## Datasource naming

All datasources are named and UID'd using the convention:

```
{team}-{service}-{environment}
```

Example: `infra-jobnik-dev`

## Environment resolution

Environment is resolved per entry in this order:

1. `environment` field on the entry itself
2. `global.mclabels.environment` (standard infra value, present in all deployments)
3. **Error** — template fails with a descriptive message naming the offending entry

## Templates

### `datasource-library.postgres`

Generates a Grafana datasource provisioning YAML block for all entries under `datasources.postgres`.

## Values

### PostgreSQL entry

| Field | Required | Default | Description |
|---|---|---|---|
| `team` | yes | — | Team name, used in datasource name |
| `service` | yes | — | Service name, used in datasource name |
| `host` | yes | — | Postgres host and port (`host:port`) |
| `database` | yes | — | Database name |
| `username` | yes | — | Database user |
| `password` | yes (no SSL) | — | Database password; not used when `ssl` is set (cert auth) |
| `environment` | no | `global.mclabels.environment` | Environment override for this entry |
| `version` | no | `1300` | Postgres server version (e.g. `1500` for PG 15) |
| `ssl` | no | — | SSL configuration block (see below); omit for non-SSL |

### SSL block (`ssl`)

When set, the connection uses client-certificate authentication (`sslmode: verify-full` by default). The `password` field is ignored. All three cert paths are required.

| Field | Required | Default | Description |
|---|---|---|---|
| `certFile` | yes | — | Absolute path to the client certificate file |
| `keyFile` | yes | — | Absolute path to the client private key file |
| `rootCertFile` | yes | — | Absolute path to the CA certificate file |
| `mode` | no | `verify-full` | One of `require`, `verify-ca`, `verify-full` |

## Examples

### No SSL (environment from global)

```yaml
global:
  mclabels:
    environment: dev

datasources:
  postgres:
    - team: infra
      service: jobnik
      host: some-host
      database: infra-jobnik
      username: mapcolonies
      password: mapcolonies-password
```

Produces datasource named `infra-jobnik-dev` with `sslmode: disable`.

### SSL with client certificates

```yaml
datasources:
  postgres:
    - team: infra
      service: opala
      environment: prod
      host: some-host
      database: infra-opala
      username: mapcolonies
      ssl:
        certFile: /etc/secrets/pg-certs/certFile
        keyFile: /etc/secrets/pg-certs/keyFile
        rootCertFile: /etc/secrets/pg-certs/caFile
```

Produces datasource named `infra-opala-prod` with `sslmode: verify-full`. No password is rendered.
