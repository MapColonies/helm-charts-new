# Raw extra-jobs escape hatch

Status: ready-for-agent

## Parent

`.scratch/prometheus-scrape-templating/spec.md` — "The raw escape hatch"

## What to build

A raw YAML passthrough that appends scrape configuration last, so a job fitting neither
generator never blocks a site on a chart release.

```yaml
prometheus:
  mapcolonies:
    scrape:
      extraJobs: ""            # raw YAML, templated, appended last
```

### It must be templated explicitly

The content is passed through `tpl` so it can reference release facts the way every other part
of this mechanism does. This needs an explicit `tpl` call: the upstream chart renders the seam
string once, and the value an `include` returns is not re-parsed, so without it the escape hatch
would be the only untemplated corner of an otherwise templated seam. Its failure mode is silent
— a literal `{{ .Release.Namespace }}` lands in a job name rather than erroring.

It renders in the **subchart's** context like everything else here, so `.Values` inside it means
the subchart's values. A site needing a literal `{{` in output escapes it as `{{ "{{" }}`; that
is rare enough not to be worth designing around.

### What it is for

The known case is a proxy exporter scraped via a target query parameter — the same relabelling
shape the blackbox generator does, but for a non-blackbox exporter. There is exactly one such
job in the site-values we can see, and generalising the blackbox generator to cover it was
rejected until a second one exists.

### The one place the namespace invariant cannot hold

Content here is opaque to the chart, so the own-namespace confinement that the generated
discovery jobs guarantee cannot be enforced. A cluster-wide discovery job written here would
collect 403s and find nothing rather than do damage, so this is a documentation matter rather
than something worth guarding. Say it in the README.

Note also that job names inside raw content are invisible to the duplicate-job-name guard for
the same reason — the guard cannot read them. That is worth stating so a site that hits a
duplicate-name reload failure knows where to look.

### Documentation

Document the key with its full values path, type and default, and be explicit about the three
things that will otherwise surprise a site author: that the content is templated and therefore
that braces are interpreted, that `.Values` inside it resolves against the subchart's values
rather than the umbrella's, and that neither the namespace invariant nor the duplicate-name
guard applies here. Include a worked example — the proxy-exporter case is the realistic one —
and show the escaping form for a literal `{{`.

## Acceptance criteria

- [ ] Raw content is appended after every generated job in the rendered `scrape_configs`.
- [ ] An empty or unset value renders nothing — no blank list entry, no stray whitespace.
- [ ] A template expression in the raw content is evaluated, not emitted literally; verify
      with both a release fact and a `.Values` reference resolving against the subchart's
      values.
- [ ] The escaping form for a literal `{{` renders as literal braces.
- [ ] The key is documented in the README with its full path, type and default.
- [ ] The README states that the content is templated in the subchart's context, that the
      own-namespace invariant cannot be enforced here and what the consequence of ignoring it
      is, and that job names here are invisible to the duplicate-job-name guard.
- [ ] The README shows a worked example, including the literal-brace escaping form.

## Blocked by

- `.scratch/prometheus-scrape-templating/issues/02-scrape-config-seam-and-self-scrape-job.md`
