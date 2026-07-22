# grafana-datasources

A Helm chart that renders a Kubernetes **Secret** containing Grafana datasource provisioning YAML. Designed for use with the [Grafana k8s-sidecar](https://github.com/kiwigrid/k8s-sidecar): the Secret carries the `mapcolonies.io/grafana-datasources` label, and the sidecar writes it into Grafana's provisioning directory.

The provisioning YAML contains connection passwords, so it is delivered as a Secret (not a ConfigMap).

## Usage

Add as a subchart dependency in your chart's `Chart.yaml`:

<!-- x-release-please-start-version -->
```yaml
dependencies:
  - name: grafana-datasources
    version: "1.0.0"
    repository: "oci://acrarolibotnonprod.azurecr.io/helm/infra"
```
<!-- x-release-please-end-version -->

Configure datasources under the `grafana-datasources` key in your chart's values. The chart renders the Secret automatically — no template file needed in the consumer chart:

```yaml
grafana-datasources:
  team: infra
  # environment: dev        # optional; defaults to global.mclabels.environment
  datasources:
    postgres:
      - service: jobnik
        host: some-host:5432
        database: infra-jobnik
        username: mapcolonies
        password: password
```

This produces a Secret named `infra-dev-grafana-datasources` with a `infra-dev.yaml` provisioning key.

## Datasource naming

Each datasource is named and UID'd using the convention:

```
{team}-{service}-{environment}
```

`team` and `environment` are instance-level; `service` is per entry. Example: `infra-jobnik-dev`.

## Environment resolution

Environment is resolved once per instance:

1. `environment` field at the instance level
2. `global.mclabels.environment` (standard infra value, present in all deployments)
3. **Error** — rendering fails with a descriptive message

## Secret naming and multiple instances

The Secret and its provisioning file are named:

```
{team}-{environment}[-{instance}]-grafana-datasources   # Secret
{team}-{environment}[-{instance}].yaml                  # data key
```

`instance` is an **optional** disambiguator. You only need it when a single release contains **more than one datasource set for the same team and environment** — for example, several services in one umbrella chart, each depending on `grafana-datasources`. Set a distinct `instance` on each to keep the Secret names (and the sidecar's on-disk filenames) unique:

```yaml
# service-a/values.yaml
grafana-datasources:
  team: infra
  instance: jobnik
  datasources: { postgres: [ ... ] }

# service-b/values.yaml
grafana-datasources:
  team: infra
  instance: opala
  datasources: { postgres: [ ... ] }
```

→ `infra-prod-jobnik-grafana-datasources` and `infra-prod-opala-grafana-datasources`. If `team`+`environment` are already unique across the release, `instance` can be omitted.

## Authentication

Every entry must provide **at least one** auth method. Password auth and TLS are orthogonal — you can use either, or both (e.g. `sslmode: require` for transport encryption together with a password):

- **Password** — set `password`.
- **Client certificate** — set both `ssl.certFile` and `ssl.keyFile` (a lone `certFile` or `keyFile` is rejected).

An entry with SSL but no password and no client certificate has no way to authenticate and is rejected.

## Values

Values are validated by `values.schema.json` (field types, enums, unknown-key rejection, and the `rootCertFile` requirement). Team/environment resolution and the auth-method requirement are enforced at render time.

### Instance-level

| Field | Required | Default | Description |
|---|---|---|---|
| `team` | yes | — | Owning team; used in datasource and Secret names |
| `environment` | no | `global.mclabels.environment` | Environment for all datasources in this instance |
| `instance` | no | — | Disambiguator for the Secret name (see above) |

### PostgreSQL entry (`datasources.postgres[]`)

| Field | Required | Default | Description |
|---|---|---|---|
| `service` | yes | — | Service name, used in datasource name |
| `host` | yes | — | Postgres host and port (`host:port`) |
| `database` | yes | — | Database name |
| `username` | yes | — | Database user |
| `password` | conditional | — | Password auth. Required unless a client certificate is provided |
| `version` | no | `1300` | Postgres server version (e.g. `1500` for PG 15) |
| `ssl` | no | — | SSL configuration block (see below) |

### SSL block (`ssl`)

Omit the entire `ssl` block for non-SSL connections (`sslmode: disable`). Cert files must already be mounted into the Grafana pod — this chart only writes the paths into the datasource, it does not create or mount any secret.

| Field | Required | Default | Description |
|---|---|---|---|
| `mode` | no | `require` | One of `require`, `verify-ca`, `verify-full` |
| `certFile` | conditional | — | Path to client certificate. Required together with `keyFile` |
| `keyFile` | conditional | — | Path to client private key. Required together with `certFile` |
| `rootCertFile` | conditional | — | Path to CA certificate. **Required** when `mode` is `verify-ca` or `verify-full` |

## Examples

### No SSL (environment from global)

```yaml
global:
  mclabels:
    environment: dev

grafana-datasources:
  team: infra
  datasources:
    postgres:
      - service: jobnik
        host: some-host:5432
        database: infra-jobnik
        username: mapcolonies
        password: password
```

Produces datasource `infra-jobnik-dev` with `sslmode: disable`, in Secret `infra-dev-grafana-datasources`.

### TLS + password auth

```yaml
grafana-datasources:
  team: infra
  environment: prod
  datasources:
    postgres:
      - service: opala
        host: some-host:5432
        database: infra-opala
        username: mapcolonies
        password: password
        ssl:
          mode: require
```

Encrypts the connection (`sslmode: require`) while authenticating with a password. No CA needed for `require`.

### Client-certificate auth with full verification

```yaml
grafana-datasources:
  team: infra
  environment: prod
  datasources:
    postgres:
      - service: opala
        host: some-host:5432
        database: infra-opala
        username: mapcolonies
        ssl:
          mode: verify-full
          certFile: /etc/secrets/pg-certs/tls.crt
          keyFile: /etc/secrets/pg-certs/tls.key
          rootCertFile: /etc/secrets/pg-certs/ca.crt
```

`verify-ca` and `verify-full` both require `rootCertFile`.
