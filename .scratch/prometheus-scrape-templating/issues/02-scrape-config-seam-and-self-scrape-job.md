# Scrape-config generation seam and the self-scrape job

Status: ready-for-agent

## Parent

`.scratch/prometheus-scrape-templating/spec.md` — "Mechanism", "Values contract",
"Named template naming"

## What to build

Give the chart the ability to generate scrape configuration at all, and prove the whole path
works end-to-end by generating the simplest of the three always-on jobs: the Prometheus
self-scrape.

The chart is a pure umbrella with no templates today. This slice adds its first `templates/`
directory, one entry-point named template, and the values wiring that hands that template to
the upstream subchart.

### The seam

The upstream subchart renders `scrape_configs` from three sources in order: its
`scrapeConfigs` map, a `scrape_configs` list under the server files' `prometheus.yml` key,
and finally the `extraScrapeConfigs` string. Only the last is passed through `tpl`, so it is
the only seam through which this chart can generate anything. The chart sets it to a single
`include` of its own entry point:

```yaml
prometheus:
  extraScrapeConfigs: '{{ include "prometheus.mapcolonies.scrapeConfigs" . }}'
```

Two consequences to accept:

- Everything generated renders **after** anything supplied by the other two sources.
  Prometheus does not care about job order, but any comparison against previously rendered
  output must be order-insensitive.
- `extraScrapeConfigs` becomes a chart-owned key. Sites must never set it. (The guard that
  enforces this is a later slice; document the rule here.)

The upstream template applies `indent 4` to the `tpl` result, so the entry point must emit a
YAML sequence starting at column 0.

### Where the values live

The `tpl` call executes in the **subchart's** context, so values at the umbrella's top level
are unreachable from the helper. This was verified empirically: umbrella top level is not
visible, under the subchart key is, under `global` is. All inputs therefore live under the
subchart key. `global` is rejected because it would leak into every other subchart for no
benefit. This is why the convention used by another chart in this repo — custom keys at the
umbrella's top level — does not apply here; that chart renders its own ConfigMap and never
crosses into a subchart context.

Our keys are grouped under a `mapcolonies` key beneath the subchart key. The grouping
distinguishes our ~ten keys from the upstream chart's sixty, and since the upstream values
schema does not set `additionalProperties: false`, a future upstream key with a name we had
chosen would merge silently rather than error. The grouping makes that impossible.

If an `alias` is ever added to the subchart dependency, this values path changes with it and
every site's values break. Note that in the README; it should not be done casually.

### Naming

The entry point is namespaced under the subchart name **and** a `mapcolonies` segment. The
repo convention `<chart-name>.<thing>` would put our helpers in the same flat global
namespace as the upstream subchart's nineteen existing `prometheus.*` definitions. There is
no collision today, but a future upstream definition matching one of ours would mean one
silently wins and the rendered config is mangled rather than rejected.

### Composition

The entry point composes, in this fixed order: self-scrape, pod service discovery, service
service discovery, blackbox jobs, static jobs, raw extra jobs. Later slices fill in the rest;
build the entry point so they slot in without restructuring it.

### This slice's job

Self-scrape, behind its own enable flag defaulting to on, so a site using an external
meta-monitoring arrangement is not double-scraped. It targets `localhost:9090`.

```yaml
prometheus:
  mapcolonies:
    scrape:
      selfScrape:
        enabled: true
```

### Documentation

This slice creates the chart's README, so it sets the shape every later slice adds to. It needs
a values reference, not a description: for every key added here, the full values path, type,
default, and what it does. Alongside it, the things a site cannot discover from the key list —
that `extraScrapeConfigs` is chart-owned and must never be set, that all inputs must sit under
the subchart key because the `tpl` call runs in the subchart's context, that generated jobs
render after any supplied through the other two upstream sources, and that adding a subchart
`alias` would move the whole values path and break every site.

Include a worked example of a complete minimal site values block and the scrape config it
renders, so the mapping from values to output is visible from the start.

## Acceptance criteria

- [ ] `helm template` on the chart with default values renders a `prometheus.yml` whose
      `scrape_configs` contains a job named `prometheus` targeting `localhost:9090`.
- [ ] Setting the self-scrape enable flag to false removes that job and, with nothing else
      declared, the seam contributes no jobs at all.
- [ ] With every generated job disabled and nothing declared, the rendered `prometheus.yml`
      is still a valid document that Prometheus will load — an empty `scrape_configs` key is
      acceptable, a malformed document is not.
- [ ] All new named templates are prefixed `prometheus.mapcolonies.` and none collides with
      an upstream `prometheus.*` definition.
- [ ] All new values live under the subchart key, grouped beneath `mapcolonies`; nothing is
      read from the umbrella's top level or from `global`.
- [ ] Every values key this slice adds is documented in the chart README with its full path,
      type, default and effect.
- [ ] The README states that `extraScrapeConfigs` is chart-owned and must never be set by a
      site, that inputs must live under the subchart key and why, that generated jobs render
      after the other two upstream sources, and that adding a subchart `alias` would break
      every site's values path.
- [ ] The README shows a worked minimal values block and the scrape config it renders.

## Blocked by

None - can start immediately.
