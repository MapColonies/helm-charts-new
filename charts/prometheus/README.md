# prometheus

Umbrella chart around the upstream [`prometheus-community/prometheus`](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus)
subchart. All subchart values live under the `prometheus` key.

## Scrape configuration

The chart generates scrape jobs from values under `prometheus.mapcolonies.scrape`.

| Path | Type | Default | Effect |
| --- | --- | --- | --- |
| `prometheus.mapcolonies.scrape.selfScrape.enabled` | bool | `true` | Renders a job named `prometheus` scraping `localhost:9090`. Turn it off where an external meta-monitoring arrangement already scrapes this Prometheus, so it is not scraped twice. |
| `prometheus.extraScrapeConfigs` | string | the chart's own template call | Chart-owned — see the rules below. Never set it. |

A site that wants the defaults writes nothing. Spelled out, the minimal values block is:

```yaml
prometheus:
  mapcolonies:
    scrape:
      selfScrape:
        enabled: true
```

and it renders, in the `prometheus.yml` key of the `infra-prometheus-server` ConfigMap:

```yaml
scrape_configs:
- job_name: prometheus
  static_configs:
    - targets:
        - localhost:9090
```

With everything turned off and nothing declared, the chart contributes no jobs and
`scrape_configs` renders with no value at all. That is still a valid document, and Prometheus
loads it.

### Rules

- **Never set `prometheus.extraScrapeConfigs`.** The chart owns it: it holds the template call
  that produces every generated job. Setting it removes them all at once, and both the render
  and the deploy still succeed.
- **Put all inputs under the `prometheus` key**, as in the table above. They are read in the
  subchart's context, so anything at the umbrella's top level is invisible to the chart.
- **Generated jobs render last**, after anything coming from `scrapeConfigs` or
  `serverFiles."prometheus.yml".scrape_configs`. Prometheus does not care about job order, but
  a diff of rendered output has to be compared order-insensitively.
- **Do not add an `alias`** to the `prometheus` dependency in `Chart.yaml`. It moves this whole
  values path and breaks every site's values.

## Upstream built-in scrape jobs

Upstream 28.16.0 ships ten built-in scrape jobs under `scrapeConfigs`, and enables all of
them by default. This chart disables all ten, because it owns the scrape configuration.

Re-enabling one means accepting an upstream job definition that this chart does not control.
Two things come with it:

- **Namespace scope.** Nine of the ten use Kubernetes service discovery, and none of them
  restricts it to a namespace, so they discover across the whole cluster. This chart sets
  `rbac.create: false` and runs under the existing `monitoring` service account, which has no
  cluster-scoped read permission. Such a job therefore collects 403s and discovers nothing,
  instead of failing loudly.
- **Relabelling.** `kubernetes-services`, for example, rewrites every target address to the
  host `blackbox`, which is not deployed here.

## Rule files

The chart does not set `serverFiles."prometheus.yml".rule_files`. It inherits the upstream
default, which is the four `/etc/config` paths. Sites should not set the key either — a site
that sets it today should delete the list rather than move it here.

Helm replaces lists instead of merging them. A site that sets `rule_files` to add one path
therefore drops the other three, and the rules in those files stop being evaluated without
any error.
