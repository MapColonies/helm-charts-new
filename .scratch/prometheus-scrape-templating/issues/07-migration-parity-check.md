# Migration parity check

Status: ready-for-agent

## Parent

`.scratch/prometheus-scrape-templating/spec.md` — "Verification"

## What to build

A one-off check proving the refactor changes nothing it did not intend to. Author a values file
reproducing the inputs of each environment currently in site-values, render the chart, extract
the `prometheus.yml` document from the server ConfigMap, and compare it as parsed data against
the currently rendered output.

This is a **throwaway script**, not something to keep. There is no lint step, no unit-test
harness and no tests directory in any chart in this repo, and building one is deliberately not
part of this work — what stands between a mistake and a bad deploy is the two render-time guards
plus the `prometheus_config_last_reload_successful` alert, which already exists in site-values.

### What to compare

The **whole document**, not only the jobs — `rule_files` is settled as part of this work, and
`global` and `alerting` should be proven untouched.

Within `scrape_configs`, compare job by job: same set of job names, and per job identical static
configs, relabel configs, metric relabel configs, parameters and intervals. The comparison must
be order-insensitive, since every generated job now renders last.

### Two deltas are expected; everything else must match

1. **`kubernetes-services` disappears.** It is enabled in the current render — nothing disables
   it today — and this work disables it. Its absence is the intended change, not a regression.
2. **Prod's two namespace lists collapse into one.** Prod currently has the pod job watching
   `devops-testing` but not `infra-dev`, while the service job watches `infra-dev` but not
   `devops-testing`. The new contract feeds both jobs one list, so prod cannot be reproduced
   exactly. Choosing what that single list contains is a values-authoring decision for whoever
   writes the migration, not a chart concern, and no alert expression references either of the
   differing namespaces. Record which list the check used and why.

Dev has no such divergence and should match exactly apart from delta 1.

### Where the current inputs live

The site-values repo, `infra/prometheus/{dev,prod}/`, on `origin/master` — the three always-on
jobs and `rule_files` under `alerts-values.yaml`, the blackbox and static jobs under
`scrape-values.yaml`. A local checkout may be on a branch that predates the current state; read
from `origin/master`.

Rendering needs `helm dependency build`, which pulls `openshift-routes` from a private ACR, so
this check needs registry auth. That is also why it cannot run in the pull-request workflow.

### A live check is a supplement, not a substitute

Snapshotting a non-production Prometheus's active targets before the deploy, deploying, and
snapshotting again is a sequential sanity check on top of the parity check, not a replacement for
it. Expect churn noise in the two discovery jobs; the static and blackbox jobs should match
exactly.

## Acceptance criteria

- [ ] A values file per environment reproduces that environment's current scrape inputs under
      the new contract.
- [ ] The check renders the chart, extracts `prometheus.yml` from the server ConfigMap, and
      compares it as parsed data — not as text — against the currently rendered output.
- [ ] The comparison covers the whole document, including `global`, `alerting` and `rule_files`,
      and is order-insensitive within `scrape_configs`.
- [ ] Per job it compares static configs, relabel configs, metric relabel configs, parameters
      and intervals.
- [ ] Dev reports no differences other than the absence of `kubernetes-services`.
- [ ] Prod reports no differences other than that absence and the collapsed namespace list, with
      the chosen list recorded.
- [ ] Any difference beyond those two is reported as a failure rather than tolerated.
- [ ] The script and its inputs are left where the migration author can rerun them, and are
      marked as throwaway so they are not mistaken for a test suite.

## Blocked by

- `.scratch/prometheus-scrape-templating/issues/05-raw-extra-jobs-escape-hatch.md`
- `.scratch/prometheus-scrape-templating/issues/06-render-time-guards.md`
