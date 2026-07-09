# datasource-library

A Helm library chart for generating Grafana datasource provisioning YAML. Designed for use with the [Grafana k8s-sidecar](https://github.com/kiwigrid/k8s-sidecar): consumer charts create a labeled ConfigMap that the sidecar picks up and writes into Grafana's provisioning directory.

## Usage

Add as a dependency in your chart's `Chart.yaml`:

<!-- x-release-please-start-version -->
```yaml
dependencies:
  - name: datasource-library
    version: "0.0.1"
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
| `password` | no | — | Password (in case ssl is not set) |
| `environment` | no | `global.mclabels.environment` | Environment override for this entry |
| `version` | no | `1300` | Postgres server version (e.g. `1500` for PG 15) |
| `ssl` | no | — | SSL configuration block (see below) |

### SSL block (`ssl`)

Omit the entire `ssl` block for non-SSL connections (`sslmode: disable`).

| Field | Required | Default | Description |
|---|---|---|---|
| `secretName` | yes | — | Kubernetes Secret name; cert paths resolve to `/etc/secrets/{secretName}/{certFile,keyFile,caFile}` |
| `mode` | no | `verify-full` | One of `require`, `verify-ca`, `verify-full` |
| `certFile` | no | `/etc/secrets/{secretName}/certFile` | Override path to client certificate |
| `keyFile` | no | `/etc/secrets/{secretName}/keyFile` | Override path to client private key |
| `rootCertFile` | no | `/etc/secrets/{secretName}/caFile` | Override path to CA certificate |

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
      password: password
```

Produces datasource named `infra-jobnik-dev`.

### SSL with default cert paths

```yaml
datasources:
  postgres:
    - team: infra
      service: opala
      environment: prod
      host: "some-host"
      database: infra-opala
      username: mapcolonies
      password: password
      ssl:
        secretName: pg-certs
```

Produces datasource named `infra-opala-prod` with cert paths:
- `/etc/secrets/pg-certs/certFile`
- `/etc/secrets/pg-certs/keyFile`
- `/etc/secrets/pg-certs/caFile`

### SSL with custom CA path

```yaml
ssl:
  secretName: pg-certs
  rootCertFile: /etc/secrets/pg-certs/custom-ca.crt
```

In this case, `certFile` and `keyFile` still use the default paths; only `rootCertFile` is overridden.
