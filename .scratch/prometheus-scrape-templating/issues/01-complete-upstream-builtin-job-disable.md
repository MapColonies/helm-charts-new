# Complete the upstream built-in scrape job disable block

Status: ready-for-agent

## Parent

`.scratch/prometheus-scrape-templating/spec.md` — "Also moving into the chart"

## What to build

The `prometheus` chart's values already disable nine of the upstream subchart's built-in
scrape jobs. Upstream 28.16.0 ships **ten**. Add the tenth, `kubernetes-services`, so the
block is complete and a reader can see the chart takes over all of them.

Then settle the `rule_files` question: the site's list is byte-identical to the upstream
subchart's default (all four `/etc/config` paths, deprecation comment included), so the
chart must restate nothing. The correct change is for the site to stop setting the key and
inherit the default. Record that in the chart's README so whoever writes the migration
deletes the list rather than moving it, and note alongside it that Helm replaces lists
rather than merging them — a site that adds one rule-file path silently drops the other
three.

### Why `kubernetes-services` is worth a second look

It is enabled today. The spec states it "is disabled at deploy time instead" — it is not:
it is disabled neither in this chart's values nor anywhere in the site-values repo
(`origin/master`), and upstream defaults it to `enabled: true`. It is therefore rendering
into the running configuration right now, and it is inert two ways over:

- Its service discovery is `role: service` with no `namespaces` block, i.e. cluster-wide.
  The chart sets `rbac.create: false` and runs under the pre-existing `monitoring` service
  account, which these clusters do not grant cluster-scoped read on — so the job collects
  403s and discovers nothing.
- Its relabelling rewrites `__address__` to the literal host `blackbox`, a hostname upstream
  assumes exists. Nothing by that name is deployed here.

That is a silently-inert job rather than a harmful one, which is why this is tidying and not
a fix. Do not confuse it with the `blackbox-exporter-*` jobs in site-values: those are
unrelated and address `infra-blackbox-exporter:9115`.

The consequence that matters downstream: disabling it **removes a job** from the rendered
output, so the migration parity check must expect that job to disappear rather than treat it
as a regression.

Rendering this chart locally needs `helm dependency build`, which pulls `openshift-routes`
from a private ACR — you need registry auth before `helm template` will work.

## Acceptance criteria

- [ ] All ten of the upstream subchart's built-in `scrapeConfigs` entries are disabled in the
      chart's values, in one contiguous block.
- [ ] A rendered `prometheus.yml` contains no job named `kubernetes-services`, and the only
      difference from a render of the current chart is that job's absence.
- [ ] The chart does not set `serverFiles."prometheus.yml".rule_files`; a render shows the
      four upstream default paths still present.
- [ ] The chart README states that `rule_files` is inherited from the upstream default, that
      sites should not set it, and that Helm replaces lists rather than merging them.
- [ ] The README states that the chart disables all ten of the upstream chart's built-in
      scrape jobs, and that a site re-enabling one is opting back into an upstream job
      definition the chart does not control — including its namespace scope.

## Blocked by

None - can start immediately.
