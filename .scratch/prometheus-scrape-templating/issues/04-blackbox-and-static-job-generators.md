# Blackbox probe and static target job generators

Status: ready-for-agent

## Parent

`.scratch/prometheus-scrape-templating/spec.md` — "Blackbox job generator",
"Static job generator"

## What to build

Two generators that turn a site's job declarations into scrape configuration, so that a site
supplies only the data. Both render nothing at all when their job map is empty.

```yaml
prometheus:
  mapcolonies:
    scrape:
      blackbox:
        address: ""            # required if any blackbox job is enabled
        jobs: {}               # per job: module, interval, targets,
                               #          address, enabled, extraConfig
      static:
        jobs: {}               # per job: metricsPath, scheme, interval, timeout,
                               #          honorTimestamps, targets, enabled, extraConfig
```

### Job names are the map keys, literally

Both maps are keyed by the **literal** job name. Short keys with a chart-supplied prefix were
rejected: alert expressions reference these job names heavily, and a constructed name appears
in no file, so searching for it would find the alerts but never the definition that creates
it.

### Blackbox generator

A site supplies module, interval, targets, and optionally an address override and an enable
flag. The chart supplies the probe metrics path, the module parameter wiring, the three
`relabel_configs` rules that move the target into a query parameter, take `instance` from it
and rewrite the address to the exporter, and the exporter address itself.

The address is given once at the generator level so that changing it is a one-line edit
rather than one per job. A site running more than one exporter can override it per job.

If a blackbox job is **enabled** and no address is resolvable for it, the render fails with a
message naming the job. A job that is declared but disabled is not checked: disabling a job is
how a site parks one, and a parked job should not have to keep satisfying requirements it is
not using.

### Static generator

Same map-keyed-by-literal-job-name shape. Per job: metrics path, scheme, interval, timeout,
honor-timestamps, targets, enable flag. The chart adds no relabelling.

Proxy exporters that need target relabelling — an exporter scraped via a target query
parameter, the way the blackbox generator does it — are **not** covered here. The single known
instance goes in the raw escape hatch. Generalising the blackbox generator to serve both would
add an address parameter, an optional module and a per-job extra-relabel passthrough to dedupe
exactly one job; that is the right move only once a second such exporter exists. Say so in the
README so the next person does not have to rediscover it.

### Targets: string or object

Shared by both generators. A target is either a bare string or an object carrying a target and
a label map. Most targets carry no labels, so requiring the object form everywhere would cost a
line each for nothing. Targets with labels become their own static config group; bare strings
collect into one group. Real site data uses both forms, including labelled probe targets
carrying ownership and scope metadata.

### Per-job passthrough

Each job in both generators accepts an `extraConfig` map, merged into the generated job, for
fields the generator does not model — `honor_labels`, parameters beyond the module, per-job
`metric_relabel_configs`, credentials. Enumerating those one at a time is a losing game, and
without a passthrough an otherwise-ordinary job has to fall all the way to the raw escape
hatch over a single line. For static jobs the passthrough earns its keep mainly through
per-job `metric_relabel_configs`: a chatty exporter is the single largest source of
cardinality in a deployment like this, and without a per-job drop path the only remedy is to
abandon the generator for that job.

### Per-job enable flag

Every declared job in both generators can be switched off individually, so a site can disable
one temporarily without deleting its target list.

### Documentation

These two generators are the keys sites will actually write, so the README has to be usable as
a reference rather than a description. Document **every** option: the generator-level keys and,
for each generator, every per-job key — full values path, type, whether it is required,
default, and what it does to the rendered job. State which fields the chart supplies and which
it will not, so a reader can tell without experimenting whether their job fits the generator
or needs `extraConfig` or the escape hatch.

Include worked examples: a minimal blackbox job (name, module, interval, bare-string targets),
a minimal static job, one job using every option including labelled targets and `extraConfig`,
and the rendered result for at least the minimal blackbox case so the mapping from values to
scrape config is visible.

## Acceptance criteria

- [ ] Empty job maps render no jobs, and no empty `scrape_configs` entries or stray
      whitespace.
- [ ] A blackbox job declared with only name, module, interval and a list of bare-string
      target URLs renders a complete probe job: probe metrics path, module parameter, one
      static config group holding the targets, and the three relabel rules.
- [ ] Changing the generator-level address changes every blackbox job's rewritten address; a
      per-job address override changes only that job.
- [ ] A labelled target renders as its own static config group carrying its labels; bare
      strings in the same job collect into a single group.
- [ ] A static job declared with metrics path, scheme, interval, timeout, honor-timestamps
      and targets renders exactly those fields plus its static config groups, with no
      relabelling added.
- [ ] `extraConfig` on a job of either kind appears in that job's rendered output and in no
      other job.
- [ ] Disabling an individual declared job removes only that job and leaves its declaration
      in values intact.
- [ ] Enabling a blackbox job with no generator-level address and no per-job override fails
      the render with a message naming the job.
- [ ] A **disabled** blackbox job with no resolvable address does not fail the render.
- [ ] Every values key this slice adds is documented in the README with its full path, type,
      required-or-not, default and effect — including each per-job key of both generators and
      both target forms.
- [ ] The README shows a minimal blackbox job, a minimal static job, a job using every
      option, and the rendered output for at least one of them.
- [ ] The README states which fields each generator supplies, what belongs in `extraConfig`,
      and that proxy exporters needing target relabelling belong in the escape hatch instead.

## Blocked by

- `.scratch/prometheus-scrape-templating/issues/02-scrape-config-seam-and-self-scrape-job.md`
