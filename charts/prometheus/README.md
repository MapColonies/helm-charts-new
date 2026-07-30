# prometheus

Umbrella chart around the upstream [`prometheus-community/prometheus`](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus)
subchart. All subchart values live under the `prometheus` key.

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
