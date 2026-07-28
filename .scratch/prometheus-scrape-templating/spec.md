# Spec: Generate Prometheus scrape configuration in the chart

Status: ready-for-agent

## Problem Statement

Every site that deploys the `prometheus` umbrella chart has to hand-write its entire
`scrape_configs` block in site-values. The result, in the one site-values repo we can
see today, is roughly 600 lines per environment of Prometheus configuration that is
mostly not site-specific at all:

- The three jobs that exist in **every** deployment — Prometheus self-scrape, pod
  service-discovery, and service service-discovery — are copied verbatim into each
  environment's values, about 255 lines each. The two environments differ only in
  their namespace lists. Roughly 120 of those lines are `metric_relabel_configs`
  cardinality-drop rules that are byte-identical between environments.
- Every blackbox-exporter job repeats the same three `relabel_configs` rules and the
  same `infra-blackbox-exporter:9115` address. With ten such jobs in one environment,
  that is about 120 lines of pure boilerplate whose only real content is a list of URLs.
- Static exporter jobs repeat `honor_timestamps`, `scrape_timeout`, `scheme` and
  `metrics_path` scaffolding around what is, again, a list of targets.

Two consequences follow. First, editing scrape configuration means editing large blocks
of YAML in which the meaningful data is a small minority, so drift between environments
is easy to introduce and hard to see — the site-values repo we can see has a pod SD job
and a service SD job in the same environment watching different namespace sets, almost
certainly unintentionally. Second, the configuration is misfiled: the three always-on
jobs live inside a file named for alerts, because they happen to sit under the same
`serverFiles` key that alert rules use.

The chart is currently a pure umbrella with no templates of its own, so it has no way to
help. It can ship fixed values, but it cannot generate anything.

## Solution

The chart takes over the *shape* of scrape configuration and leaves sites to supply only
the *data*.

The chart always renders the three jobs that exist everywhere, each behind an enable
flag, with their cardinality-drop rules built in and a single namespace list templated
into both service-discovery jobs. Alongside those it offers two generators — one for
blackbox-exporter probe jobs, one for plain static-target jobs — that render nothing at
all unless a site declares jobs. A raw escape hatch takes anything that fits neither
generator.

A site therefore declares a namespace list, and for each job it wants, a name, a module
or metrics path, an interval, and a list of targets. Everything structural is supplied by
the chart. A site that has no Jenkins gets no Jenkins job, because the chart never
mentions Jenkins.

The chart deliberately contains **no** MapColonies deployment vocabulary. No job names,
no domain names, no exporter hostnames, no default target lists. Which exporters and
probes exist is a deployment decision made per site, and sites exist that this repo
cannot see.

## User Stories

1. As an infra engineer configuring a new site, I want the Prometheus self-scrape job to
   exist without me writing it, so that a fresh deployment monitors itself by default.
2. As an infra engineer configuring a new site, I want pod service-discovery to exist
   without me writing it, so that annotated workloads are scraped by default.
3. As an infra engineer configuring a new site, I want service service-discovery to exist
   without me writing it, so that annotated services are scraped by default.
4. As an infra engineer, I want to supply one namespace list that both service-discovery
   jobs use, so that the two jobs cannot silently drift apart.
5. As an infra engineer running a site where pod discovery is inappropriate, I want to
   turn off the pod service-discovery job with a flag, so that I am not forced to accept
   a job my site does not want.
6. As an infra engineer, I want to turn off the service service-discovery job with a
   flag, for the same reason.
7. As an infra engineer, I want to turn off the self-scrape job with a flag, so that a
   site using an external meta-monitoring arrangement is not double-scraped.
8. As an infra engineer, I want the high-cardinality label and histogram-bucket drop
   rules to come from the chart, so that I do not copy 120 lines of regexes into every
   environment.
9. As an infra engineer whose site runs components the chart's drop rules do not cover,
   I want to append my own drop rules to the pod discovery job, so that I can control
   cardinality without a chart change.
10. As an infra engineer, I want to append my own drop rules to the service discovery
    job independently of the pod one, because the two jobs drop different metric families.
11. As an infra engineer, I want to declare a blackbox probe job by giving only its name,
    module, interval and target URLs, so that the probe relabelling scaffolding is not my
    problem.
12. As an infra engineer, I want to give the blackbox exporter's address once, so that
    changing it is a one-line edit rather than ten.
13. As an infra engineer running more than one blackbox exporter, I want to override the
    address on an individual job, so that a job can point at a different exporter.
14. As an infra engineer, I want to write a probe target as a bare URL string, so that
    the common case is one line per target.
15. As an infra engineer, I want to attach labels to an individual probe target when I
    need to, so that targets can carry ownership and scope metadata without me hand-writing
    static config groups.
16. As an infra engineer, I want to declare a plain static scrape job with a metrics path,
    scheme, interval, timeout and targets, so that exporters that are not blackbox probes
    are equally terse.
17. As an infra engineer, I want to attach labels to static job targets, so that exporter
    metrics carry the same ownership metadata as probes.
18. As an infra engineer with a job that fits neither generator, I want a raw escape hatch
    that appends verbatim scrape config, so that an unusual job never blocks me on a chart
    release.
19. As an infra engineer, I want jobs I do not declare to produce no output at all, so
    that my rendered configuration contains only what my site actually has.
20. As an infra engineer, I want to switch an individual declared job off with a flag, so
    that I can disable it temporarily without deleting its target list.
21. As an infra engineer, I want the chart to fail loudly if I declare blackbox jobs
    without giving an exporter address, so that I find out at render time rather than by
    reading a broken config in the cluster.
22. As an infra engineer upgrading a site to this chart, I want the render to fail with an
    explanatory message if my values still override the key the chart now owns, so that I
    cannot accidentally deploy a Prometheus with no service discovery at all.
23. As an alert author, I want the job names I reference in alert expressions to appear
    literally in the values that create them, so that searching for a job name finds both
    its alerts and its definition.
24. As a chart maintainer, I want our additions grouped under a single clearly-named key,
    so that a reader can tell at a glance which values are ours and which come from the
    upstream chart.
25. As a chart maintainer, I want our named templates to sit outside the upstream chart's
    template namespace, so that a future upstream release cannot silently collide with
    ours.
26. As a chart maintainer, I want the fixed rule-file paths to live in the chart, so that
    sites do not repeat a list that has no site-specific content.
27. As an infra engineer migrating an existing site, I want to prove the rendered scrape
    configuration is unchanged before I deploy, so that a refactor cannot quietly alter
    what is monitored.
28. As an infra engineer reading a site's values, I want scrape configuration to be
    findable under a scrape-shaped key rather than mixed into a file named for alerts, so
    that the file layout reflects what the content is.

## Implementation Decisions

### Mechanism: the templated `extraScrapeConfigs` seam

The upstream `prometheus` subchart renders scrape configuration from three sources, in
this order: a `scrapeConfigs` map, a `scrape_configs` list under the server files'
`prometheus.yml` key, and finally an `extraScrapeConfigs` string. Only the last of these
is passed through `tpl`. That makes it the only seam through which the chart can generate
anything, so the chart sets `extraScrapeConfigs` to a single `include` of its own helper
and generates everything from there.

Two consequences the implementation must accept:

- All generated jobs render **after** anything supplied via the other two sources.
  Prometheus does not care about job order, but any comparison against previously
  rendered output must be order-insensitive.
- `extraScrapeConfigs` becomes a chart-owned key. Sites must never set it; they use the
  raw escape hatch instead.

### Values must live under the subchart key

The `tpl` call executes in the **subchart's** context, not the umbrella's. Values at the
umbrella's top level are unreachable from the helper. This was verified empirically by
rendering a probe helper against three locations:

| value location | visible inside the helper |
| --- | --- |
| umbrella top level | no |
| under the subchart key | yes |
| under `global` | yes |

All inputs therefore live under the subchart key. `global` is rejected because it would
leak into every other subchart for no benefit.

Note that this is why the convention used by another chart in this repo — custom keys at
the umbrella's top level, consumed by the umbrella's own templates — does not apply here.
That chart renders its own ConfigMap and never crosses into a subchart context.

### Values contract

Our keys are grouped under a `mapcolonies` key beneath the subchart key. The grouping is
not strictly required for correctness, but it distinguishes our roughly ten keys from the
upstream chart's sixty, and the upstream values schema does not set
`additionalProperties: false`, so a future upstream key with a name we had chosen would
merge silently rather than error. The grouping makes that impossible.

```yaml
prometheus:                    # subchart name — mandatory, not a choice
  extraScrapeConfigs: '{{ include "prometheus.mapcolonies.scrapeConfigs" . }}'
  mapcolonies:
    scrape:
      selfScrape:
        enabled: true
      kubernetes:
        namespaces: []
        pod:
          enabled: true
          extraMetricRelabelConfigs: []
        service:
          enabled: true
          extraMetricRelabelConfigs: []
      blackbox:
        address: ""            # required if any blackbox job is declared
        jobs: {}
      static:
        jobs: {}
      extraJobs: ""            # raw YAML, appended verbatim
```

If an `alias` is ever added to the subchart dependency, the values path changes with it
and every site's values break. This should not be done casually.

### Generator composition and ordering

One entry-point helper composes, in this fixed order: self-scrape, pod service discovery,
service service discovery, blackbox jobs, static jobs, raw extra jobs. Each of the first
three is gated on its own enable flag, defaulting to on. The two generators emit nothing
when their job maps are empty.

### Service-discovery jobs

Both service-discovery jobs hardcode own-namespace discovery and receive the same single
namespace list. The list does not need to repeat the release namespace.

Each carries its own chart-owned `metric_relabel_configs` block: a shared high-cardinality
label drop, plus the pod job's histogram-bucket drops for the log, trace and collector
components, and the service job's drops for unused cluster-state metric families. These
are fixed, not overridable — dropping metrics for a component a site does not run is a
no-op, so there is no need to let sites replace them. Each job additionally reads its own
append key so a site can add rules.

### Blackbox job generator

Keyed by a map whose keys are the **literal** job names. Short keys with a chart-supplied
prefix were rejected: alert expressions reference these job names heavily, and a
constructed name appears in no file, so searching for it would find the alerts but never
the definition that creates it.

Per job a site supplies module, interval, targets, and optionally an address override and
an enable flag. The chart supplies the probe metrics path, the module parameter wiring,
the three `relabel_configs` rules that move the target into a query parameter and rewrite
the address to the exporter, and the exporter address itself.

A target is either a bare string or an object carrying a target and a label map. Most
targets carry no labels, so requiring the object form everywhere would cost a line each
for nothing. Targets with labels become their own static config group.

If any blackbox job is declared and no address is resolvable for it, the render fails.

### Static job generator

Same map-keyed-by-literal-job-name shape. Per job: metrics path, scheme, interval,
timeout, honor-timestamps, targets, enable flag. Targets accept the same string-or-object
shorthand. The chart adds no relabelling.

Proxy exporters that need target relabelling — an exporter scraped via a target query
parameter, as the blackbox generator does — are **not** covered. The single known instance
goes in the raw escape hatch. Generalising the blackbox generator to serve both would add
an address parameter, an optional module and a per-job extra-relabel passthrough to
dedupe exactly one job; that is the right move only once a second such exporter exists.

### Guard against silent loss of service discovery

Because everything now flows through one key that sites previously wrote themselves, a
site that adopts the chart without rewriting its values would render cleanly, deploy
cleanly, and come up with no pod or service discovery whatsoever. That is the worst
available failure mode: silent, and invisible in a diff.

The chart therefore renders a guard that inspects the owned key and fails if it no longer
contains the chart's own include. A warning was considered and rejected: Helm has no
warning primitive, so a warning must ride on release notes that scroll past or on a
rendered marker object, and neither reliably stops the deploy. A hard failure is correct
here — the escape hatch means no site has a legitimate reason to override the key, so the
guard should never fire on valid usage.

An accepted consequence: a site cannot adopt this chart incrementally. Taking the new
chart and rewriting the site's values are one atomic step.

### Named template naming

The entry point is namespaced under the subchart name **and** a `mapcolonies` segment.
The repo convention is `<chart-name>.<thing>`, which here would place our helpers in the
same flat global namespace as the upstream subchart's nineteen existing `prometheus.*`
definitions. There is no collision today, but a future upstream definition matching one of
ours would mean one silently wins and the rendered config is mangled rather than rejected.
The extra segment removes that risk permanently.

### Also moving into the chart

The rule-file path list moves into the chart. The paths are fixed and contain nothing
site-specific; it is only in site-values today because it shares a key with alert rules.

The existing block that disables the upstream chart's own built-in scrape jobs stays
exactly as it is — those jobs are still unwanted, since the chart now generates its own.

## Testing Decisions

### What makes a good test here

A good test asserts on what a deployer would observe: the scrape configuration that ends
up in the rendered server ConfigMap. It should not assert on which helper produced which
fragment, on indentation, or on the internal structure of the templates. A test that
breaks when a helper is split in two, without any change to rendered output, is testing
the wrong thing.

### The seam

**One seam, and it is the highest available:** render the chart with a given values file,
extract the Prometheus configuration document from the rendered server ConfigMap, parse it,
and assert on it as data. Every behaviour in this spec is observable there — the three
always-on jobs and their flags, both generators, the target shorthand, label groups, the
namespace list reaching both discovery jobs, escape-hatch ordering, and the fact that
undeclared jobs produce nothing. The two failure conditions are observable at the same
seam as a failed render carrying an explanatory message.

No lower seam is needed and none should be introduced. No cluster is required.

### Prior art

There is none in this repo. CI currently validates only the `domain` annotation on each
chart; there is no lint step, no unit-test harness, and no tests directory in any chart.
The closest existing practice is the values schema shipped by two other charts, which
validates input shape but says nothing about rendered output.

The harness is therefore a green-field decision. Whichever is chosen, it should be wired
into the existing per-chart pull-request matrix so it runs on change.

### Cases to cover

- Defaults only: the three always-on jobs render; no blackbox, static or extra jobs appear.
- Each enable flag off individually removes exactly its own job and nothing else.
- The namespace list appears in both discovery jobs, and own-namespace discovery is set on
  both.
- Chart-owned drop rules are present on both discovery jobs; the append keys add rules
  without displacing them, and each append key affects only its own job.
- A blackbox job renders with the probe path, module parameter, the three relabel rules and
  the shared address.
- A per-job address override takes precedence over the shared address.
- A blackbox job declared with no address available fails the render with a message.
- Bare-string and labelled-object targets both render, and labelled targets form their own
  static config groups.
- A static job renders its path, scheme, interval, timeout and targets, with no relabelling
  added.
- Escape-hatch content renders verbatim and last.
- A per-job enable flag set off removes that job while leaving its siblings.
- Overriding the chart-owned scrape key fails the render with an explanatory message.

### Migration parity check

Separately from the permanent tests, a one-off check proves the refactor changes nothing.
Author a values file reproducing the inputs of each environment currently in site-values,
render, extract the Prometheus configuration, and compare job-by-job as parsed data
against the currently rendered output: same set of job names, and per job identical static
configs, relabel configs, metric relabel configs, parameters and intervals. The comparison
must be order-insensitive, since all generated jobs now render last.

This is a throwaway script, not a test to keep. A live check — snapshot a non-production
Prometheus's active targets before the deploy, deploy, snapshot again, compare — is a
sequential sanity check on top of the parity check, not a substitute for it. Expect churn
noise in the two discovery jobs; the static and blackbox jobs should match exactly.

## Out of Scope

- **The site-values rewrite.** Migrating the existing site to the new contract, and the
  chart version bump that goes with it, is the next step and is tracked separately.
- **Resolving the existing namespace-list divergence.** One environment's pod and service
  discovery jobs currently watch different namespace sets. Collapsing them into the single
  namespace list is a values-authoring decision for whoever writes the migration, not a
  chart concern. No alert expression references either of the differing namespaces.
- **Alert and recording rules.** Untouched. They keep referencing job names as literal
  strings, which is why job names remain literal in values.
- **The blackbox exporter's own chart**, its duplicated module definitions, and the
  plaintext API-key JWT currently committed in that chart's site-values. Separate concern.
- **Collapsing blackbox jobs by module instead of by domain.** Would reduce the job count
  but rename every job and break roughly forty alert expressions.
- **Generalising the blackbox generator to cover proxy exporters.** Revisit when a second
  such exporter exists.
- **Chart versioning and release mechanics.** Handled by the repo's existing release
  tooling.

## Further Notes

The line-count reduction is a means, not the goal. The goal is that a site's scrape
configuration contains only decisions a site actually makes, so that a divergence between
two environments is visible as a difference in data rather than buried in a few hundred
lines of identical scaffolding — the existing namespace divergence being precisely the
failure this prevents.

The chart deliberately encodes no knowledge of which exporters or probe targets exist.
Sites this repo cannot see deploy the same chart, and a chart that shipped a default job
list would be wrong for all of them.
