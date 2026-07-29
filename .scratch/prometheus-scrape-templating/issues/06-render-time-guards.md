# Render-time guards: owned key and duplicate job names

Status: ready-for-agent

## Parent

`.scratch/prometheus-scrape-templating/spec.md` — "Render-time guards"

## What to build

Two guards that fail the render. Both cover mistakes a rendered diff will not show, and both
matter more than they look because of how this deployment reloads configuration.

### Why failing the render is the only option that works

The Prometheus server has no `checksum/config` annotation, so a configuration change does not
restart the pod. The `prometheus-config-reloader` sidecar watches `/etc/config` and POSTs
`/-/reload`; if Prometheus rejects the new configuration it **keeps serving the old one**, and
the deploy looks entirely successful. An invalid generated configuration is therefore not a
loud failure at all — it is a silent no-op that leaves the cluster running configuration that
no longer matches the repository.

### Guard 1 — a site overriding the chart-owned key

Everything now flows through `extraScrapeConfigs`. A site that sets it clobbers the chart's
include and loses every generated job at once, rendering cleanly and deploying cleanly on the
way.

The guard inspects the owned key and fails if it no longer contains the chart's own include.
Appending to the include rather than replacing it still passes.

A warning was considered and rejected: Helm has no warning primitive, so a warning must ride on
release notes that scroll past or on a rendered marker object, and neither reliably stops the
deploy. A hard failure is correct here — the escape hatch means no site has a legitimate reason
to override the key, so the guard should never fire on valid usage.

The failure message has to say what to do, not just what is wrong: use the raw escape hatch
instead, and here is the key to remove.

### Guard 2 — two jobs sharing a job name

Prometheus refuses to load a configuration containing duplicate `job_name` values, and the new
contract makes collisions reachable: a blackbox job key equal to a static job key, or either
equal to a job left enabled in the upstream `scrapeConfigs` map. Helm renders duplicates
perfectly happily.

The guard checks the assembled job names and fails on a collision, naming the colliding name and
both sources. It must consider the generated discovery and self-scrape job names, both
generators' map keys, and any job still enabled in the upstream `scrapeConfigs` map. Raw escape
hatch content is opaque and cannot be checked.

### What this deliberately does not cover

Not everything Prometheus validates — a malformed regex, a `scrape_timeout` larger than its
`scrape_interval`, an invalid relabel action. Validating those properly would mean running
`promtool` against the rendered configuration from a Helm hook, which was considered and
rejected: to avoid shipping a second image the hook has to reach into the subchart's
`server.image` values, whose tag defaults to the subchart's `appVersion`, so the umbrella would
have to replicate that defaulting and the two charts' `appVersion` fields would have to be kept
in step by hand indefinitely. That is more machinery, and more coupling into subchart internals,
than the problem justifies — this chart should stay a thin layer over the upstream one.

The general case is covered instead by an alert on
`prometheus_config_last_reload_successful`, which catches every cause of a failed reload rather
than only the ones this feature introduces and costs the chart nothing. That alert already
exists in site-values, so the prerequisite is satisfied; it is not part of this chart.

### An accepted consequence

Guard 1 means a site cannot adopt this chart incrementally. Taking the new chart and rewriting
the site's values are one atomic step. That makes this a breaking change for every consumer.
Record it in the README as an upgrade note, since it is the thing a site operator most needs to
know before pulling this version.

### Documentation

Document both guards in the README: what each one checks, the exact condition that trips it, and
what to change to satisfy it. A site that hits a failed render should be able to find the cause
by searching the message text. Include the upgrade note above, and state explicitly that the
guards do not validate the configuration Prometheus-side and that the reload alert is what
covers the rest.

## Acceptance criteria

- [ ] Setting `extraScrapeConfigs` to something that does not contain the chart's include
      fails the render, with a message naming the key and pointing at the escape hatch.
- [ ] Appending to the chart's include rather than replacing it still renders.
- [ ] Default values render without tripping either guard.
- [ ] A blackbox job key equal to a static job key fails the render, naming the duplicate and
      both sources.
- [ ] A generator job key equal to a job left enabled in the upstream `scrapeConfigs` map
      fails the render.
- [ ] A generator job key equal to one of the chart's own generated job names — the
      self-scrape or either discovery job — fails the render.
- [ ] A duplicate name introduced only inside raw escape-hatch content does not fail the
      render, and the README says why.
- [ ] The README documents both guards, the condition that trips each, how to satisfy it, and
      that the guards do not replace Prometheus-side validation.
- [ ] The README carries an upgrade note stating that adopting this version and rewriting a
      site's values is one atomic step, and that this is a breaking change.

## Blocked by

- `.scratch/prometheus-scrape-templating/issues/01-complete-upstream-builtin-job-disable.md`
- `.scratch/prometheus-scrape-templating/issues/03-kubernetes-service-discovery-jobs.md`
- `.scratch/prometheus-scrape-templating/issues/04-blackbox-and-static-job-generators.md`
