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
5. As an infra engineer, I want it to be impossible for any values combination to produce
   cluster-wide discovery, because my clusters do not grant cluster-scoped RBAC and a job
   that escaped the restriction would quietly discover nothing rather than fail.
6. As an infra engineer running a site where pod discovery is inappropriate, I want to
   turn off the pod service-discovery job with a flag, so that I am not forced to accept
   a job my site does not want.
7. As an infra engineer, I want to turn off the service service-discovery job with a
   flag, for the same reason.
8. As an infra engineer, I want to turn off the self-scrape job with a flag, so that a
   site using an external meta-monitoring arrangement is not double-scraped.
9. As an infra engineer, I want the high-cardinality label and histogram-bucket drop
   rules to come from the chart, so that I do not copy 120 lines of regexes into every
   environment.
10. As an infra engineer whose site runs components the chart's drop rules do not cover,
    I want to append my own drop rules to the pod discovery job, so that I can control
    cardinality without a chart change.
11. As an infra engineer, I want to append my own drop rules to the service discovery
    job independently of the pod one, because the two jobs drop different metric families.
12. As an infra engineer who needs a series the chart's rules drop, I want to turn the
    chart-owned rules off for that job and supply my own set, so that recovering a metric
    I actually use does not require a chart release.
13. As an infra engineer, I want to declare a blackbox probe job by giving only its name,
    module, interval and target URLs, so that the probe relabelling scaffolding is not my
    problem.
14. As an infra engineer, I want to give the blackbox exporter's address once, so that
    changing it is a one-line edit rather than ten.
15. As an infra engineer running more than one blackbox exporter, I want to override the
    address on an individual job, so that a job can point at a different exporter.
16. As an infra engineer, I want to write a probe target as a bare URL string, so that
    the common case is one line per target.
17. As an infra engineer, I want to attach labels to an individual probe target when I
    need to, so that targets can carry ownership and scope metadata without me hand-writing
    static config groups.
18. As an infra engineer, I want to declare a plain static scrape job with a metrics path,
    scheme, interval, timeout and targets, so that exporters that are not blackbox probes
    are equally terse.
19. As an infra engineer, I want to attach labels to static job targets, so that exporter
    metrics carry the same ownership metadata as probes.
20. As an infra engineer whose job needs one field the generator does not model — a
    per-job metric drop rule, an extra parameter, credentials — I want to pass it through
    on that job, so that a single missing line does not cost me the whole generator.
21. As an infra engineer with a job that fits neither generator, I want a raw escape hatch
    that appends scrape config, so that an unusual job never blocks me on a chart release.
22. As an infra engineer using the escape hatch, I want its content templated like
    everything else here, so that a raw job can reference release facts instead of
    silently emitting braces into a job name.
23. As an infra engineer, I want jobs I do not declare to produce no output at all, so
    that my rendered configuration contains only what my site actually has.
24. As an infra engineer, I want to switch an individual declared job off with a flag, so
    that I can disable it temporarily without deleting its target list.
25. As an infra engineer, I want the chart to fail loudly if I enable a blackbox job
    without giving an exporter address, so that I find out at render time rather than by
    reading a broken config in the cluster.
26. As an infra engineer, I want the render to fail if two of my jobs would end up sharing
    a job name, because Prometheus rejects such a configuration on load and this
    deployment's reload path turns that rejection into a silent no-op.
27. As an infra engineer upgrading a site to this chart, I want the render to fail with an
    explanatory message if my values still override the key the chart now owns, so that I
    cannot accidentally deploy a Prometheus with no generated jobs at all.
28. As an alert author, I want the job names I reference in alert expressions to appear
    literally in the values that create them, so that searching for a job name finds both
    its alerts and its definition.
29. As a chart maintainer, I want our additions grouped under a single clearly-named key,
    so that a reader can tell at a glance which values are ours and which come from the
    upstream chart.
30. As a chart maintainer, I want our named templates to sit outside the upstream chart's
    template namespace, so that a future upstream release cannot silently collide with
    ours.
31. As a chart maintainer, I want the fixed rule-file paths out of site-values, so that
    sites do not repeat a list that has no site-specific content.
32. As an infra engineer migrating an existing site, I want to prove the rendered
    configuration is unchanged before I deploy, so that a refactor cannot quietly alter
    what is monitored.
33. As an infra engineer reading a site's values, I want scrape configuration to be
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
        namespaces: []         # own namespace always included; empty means own only
        pod:
          enabled: true
          builtinMetricRelabelConfigs: true
          extraMetricRelabelConfigs: []
        service:
          enabled: true
          builtinMetricRelabelConfigs: true
          extraMetricRelabelConfigs: []
      blackbox:
        address: ""            # required if any blackbox job is enabled
        jobs: {}               # per job: module, interval, targets,
                               #          address, enabled, extraConfig
      static:
        jobs: {}               # per job: metricsPath, scheme, interval, timeout,
                               #          honorTimestamps, targets, enabled, extraConfig
      extraJobs: ""            # raw YAML, templated, appended last
```

If an `alias` is ever added to the subchart dependency, the values path changes with it
and every site's values break. This should not be done casually.

### Generator composition and ordering

One entry-point helper composes, in this fixed order: self-scrape, pod service discovery,
service service discovery, blackbox jobs, static jobs, raw extra jobs. Each of the first
three is gated on its own enable flag, defaulting to on. The two generators emit nothing
when their job maps are empty.

### Service-discovery jobs

Both service-discovery jobs receive the same single namespace list. The list does not need
to repeat the release namespace.

Confinement to the release's own namespaces is an **invariant, not a default**.
`own_namespace: true` is emitted unconditionally and is not exposed as a value, and no
combination of inputs can cause the `namespaces` block to be omitted or emitted without it.
This matters because in Kubernetes service discovery an absent or empty namespace
restriction means *all* namespaces — and these clusters do not grant the cluster-scoped RBAC
that would require, so a job that escaped the restriction would not fail loudly, it would
collect 403s and discover nothing. An empty namespace list therefore means
own-namespace-only, which is both the default and the floor.

Each job carries its own chart-owned `metric_relabel_configs` block: a shared
high-cardinality label drop, plus the pod job's histogram-bucket drops for the log, trace
and collector components, and the service job's drops for unused cluster-state metric
families.

Each job additionally reads its own append key so a site can add rules. Appended rules run
**after** the chart's own, which means they can drop further but can never recover a series
the chart has already dropped — relabelling is one-way. The common case needs nothing more:
dropping metrics for a component a site does not run is a no-op. But a site that *does* run
that component and genuinely needs one of the dropped series would otherwise have no
recourse short of a chart release, or abandoning the generated job entirely. Each discovery
job therefore also carries a flag that turns the chart-owned block off, at which point the
append key becomes the whole list. It defaults to on.

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

Each job also accepts an `extraConfig` map, merged into the generated job, for fields the
generator does not model — `honor_labels`, parameters beyond the module, per-job
`metric_relabel_configs`, credentials. Enumerating those one at a time is a losing game, and
without a passthrough an otherwise-ordinary job has to fall all the way to the raw escape
hatch over a single line.

If a blackbox job is **enabled** and no address is resolvable for it, the render fails. A
job that is declared but disabled is not checked: disabling a job is how a site parks one,
and a parked job should not have to keep satisfying requirements it is not using.

### Static job generator

Same map-keyed-by-literal-job-name shape. Per job: metrics path, scheme, interval,
timeout, honor-timestamps, targets, enable flag. Targets accept the same string-or-object
shorthand. The chart adds no relabelling.

Each job also accepts an `extraConfig` map on the same reasoning as the blackbox generator.
Here the passthrough earns its keep mainly through per-job `metric_relabel_configs`: a
chatty exporter is the single largest source of cardinality in a deployment like this, and
without a per-job drop path the only remedy is to abandon the generator for that job.

Proxy exporters that need target relabelling — an exporter scraped via a target query
parameter, as the blackbox generator does — are **not** covered. The single known instance
goes in the raw escape hatch. Generalising the blackbox generator to serve both would add
an address parameter, an optional module and a per-job extra-relabel passthrough to
dedupe exactly one job; that is the right move only once a second such exporter exists.

### The raw escape hatch

Raw content is appended last and is passed through `tpl`, so it can reference release facts
the way every other part of this mechanism does. Note that `tpl` renders the seam string
once; the value an `include` returns is not re-parsed, so without an explicit `tpl` the
escape hatch would be the only untemplated corner of an otherwise templated seam — and its
failure mode is silent, emitting a literal `{{ .Release.Namespace }}` into a job name rather
than erroring. It renders in the **subchart's** context like everything else here, so
`.Values` inside it means the subchart's values. A site that needs a literal `{{` in output
escapes it as `{{ "{{" }}`; that is rare enough not to be worth designing around.

The escape hatch is the one place the own-namespace invariant cannot be enforced, since its
content is opaque to the chart. A cluster-wide discovery job written there would collect
403s and find nothing rather than do damage, so this is a documentation matter rather than
something worth guarding.

### Render-time guards

Two things can go wrong in ways a rendered diff will not show, and both are worth failing
the render over.

**A site overriding the key the chart now owns.** Everything now flows through
`extraScrapeConfigs`. A site that sets it clobbers the chart's include and loses every
generated job at once — rendering cleanly and deploying cleanly on the way. The chart
therefore renders a guard that inspects the owned key and fails if it no longer contains the
chart's own include; appending to the include rather than replacing it still passes. A
warning was considered and rejected: Helm has no warning primitive, so a warning must ride
on release notes that scroll past or on a rendered marker object, and neither reliably stops
the deploy. A hard failure is correct here — the escape hatch means no site has a legitimate
reason to override the key, so the guard should never fire on valid usage.

**Two jobs sharing a job name.** Prometheus refuses to load a configuration containing
duplicate `job_name` values, and the new contract makes collisions reachable: a blackbox job
key equal to a static job key, or either equal to a job left enabled in the upstream
`scrapeConfigs` map. Helm renders duplicates perfectly happily. The chart therefore checks
the assembled job names and fails on a collision.

Why that is worth a guard rather than something to leave to Prometheus: the server has no
`checksum/config` annotation, so a configuration change does not restart the pod. The
`prometheus-config-reloader` sidecar watches `/etc/config` and POSTs `/-/reload`; if
Prometheus rejects the new configuration it **keeps serving the old one**, and the deploy
looks entirely successful. An invalid generated configuration is therefore not a loud
failure at all — it is a silent no-op that leaves the cluster running configuration that no
longer matches the repository.

The render-time check covers the collision case, which is the one this contract introduces.
It does not cover everything Prometheus validates — a malformed regex, a `scrape_timeout`
larger than its `scrape_interval`, an invalid relabel action. Validating those properly
would mean running `promtool` against the rendered configuration from a Helm hook, which was
considered and rejected: to avoid shipping a second image the hook has to reach into the
subchart's `server.image` values, whose tag defaults to the subchart's `appVersion`, so the
umbrella would have to replicate that defaulting and the two charts' `appVersion` fields
would have to be kept in step by hand indefinitely. That is more machinery, and more
coupling into subchart internals, than the problem justifies — this chart should stay a thin
layer over the upstream one. The general case is covered instead by an alert on
`prometheus_config_last_reload_successful`, which catches every cause of a failed reload
rather than only the ones this feature introduces and costs the chart nothing. That alert
lives with the rest of the alert rules; it is a prerequisite for this work rather than part
of it.

An accepted consequence of the first guard: a site cannot adopt this chart incrementally.
Taking the new chart and rewriting the site's values are one atomic step. That makes this a
breaking change for every consumer, and it has to be released as one.

### Named template naming

The entry point is namespaced under the subchart name **and** a `mapcolonies` segment.
The repo convention is `<chart-name>.<thing>`, which here would place our helpers in the
same flat global namespace as the upstream subchart's nineteen existing `prometheus.*`
definitions. There is no collision today, but a future upstream definition matching one of
ours would mean one silently wins and the rendered config is mangled rather than rejected.
The extra segment removes that risk permanently.

### Also moving into the chart

The rule-file path list moves out of site-values. Check before moving it *into* the chart
rather than simply deleting it: the upstream chart already defaults
`serverFiles."prometheus.yml".rule_files` to the four `/etc/config` paths, so if the site's
list matches, the correct change is to stop setting it and inherit the default. Restating it
here is warranted only if the site's list actually differs. Either way, note that Helm
replaces lists rather than merging them, so wherever the list ends up living, a site adding
one path silently drops the rest.

The block that disables the upstream chart's own built-in scrape jobs moves into the chart,
and is completed while it moves. Upstream 28.16.0 ships ten built-in jobs; this chart
disables nine. `kubernetes-services` is not among them and is disabled at deploy time
instead, so it should be disabled here alongside the others. Independently of the tidying,
that job does cluster-wide `role: service` discovery with no namespace restriction and
rewrites `__address__` to a bare `blackbox` host — in these clusters it is not merely
redundant, it is a job the RBAC cannot serve.

## Verification

### No permanent test suite

There is no lint step, no unit-test harness and no tests directory in any chart in this
repo; CI validates only the `domain` annotation. Building a harness is deliberately not part
of this work. Recording the decision here so it is not later mistaken for an oversight: what
stands between a mistake and a bad deploy is the two render-time guards above, plus the
`prometheus_config_last_reload_successful` alert that covers everything a render-time check
cannot see.

Worth knowing if this is ever revisited: the natural seam — extract the `prometheus.yml`
document from the rendered server ConfigMap and assert on it as parsed data — is awkward for
the obvious Helm harness, because that document is a *string* inside the ConfigMap's `data`
and helm-unittest can only pattern-match it. Asserting on it as data means rendering with
`helm template` and parsing the embedded document in a general-purpose runner. A harness
would also need registry credentials in CI: rendering requires `helm dependency build`,
which pulls `openshift-routes` from a private ACR that the pull-request workflow has no
auth for.

### Migration parity check

A one-off check proves the refactor changes nothing. Author a values file reproducing the
inputs of each environment currently in site-values, render, extract the `prometheus.yml`
document from the server ConfigMap, and compare it as parsed data against the currently
rendered output.

Compare the **whole document**, not only the jobs — `rule_files` moves as part of this work,
and `global` and `alerting` should be proven untouched. Within `scrape_configs`, compare
job-by-job: same set of job names, and per job identical static configs, relabel configs,
metric relabel configs, parameters and intervals. The comparison must be order-insensitive,
since all generated jobs now render last.

This is a throwaway script, not something to keep. A live check — snapshot a non-production
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
- **The configuration-reload alert.** An alert on `prometheus_config_last_reload_successful`
  belongs with the rest of the alert rules, not in this chart. It is a prerequisite for this
  work rather than a part of it — see the guards section for why it matters here.
- **A permanent test harness for this or any chart.** Decided against; see Verification.
- **Chart versioning and release mechanics.** Handled by the repo's existing release
  tooling. *That* this is a breaking release is a fact of the design and is recorded above;
  how the version gets cut is not this spec's concern.

## Further Notes

The line-count reduction is a means, not the goal. The goal is that a site's scrape
configuration contains only decisions a site actually makes, so that a divergence between
two environments is visible as a difference in data rather than buried in a few hundred
lines of identical scaffolding — the existing namespace divergence being precisely the
failure this prevents.

The chart deliberately encodes no knowledge of which exporters or probe targets exist.
Sites this repo cannot see deploy the same chart, and a chart that shipped a default job
list would be wrong for all of them.
