# gatekeeper-constraints

Helm chart for the Gatekeeper rules of the cluster. It wraps upstream Gatekeeper and adds:

- **Pod rules**: Pods need the right **labels** and **annotations**. These rules only warn.
- **Workload rules**: Deployments and StatefulSets must set CPU requests and limits at a 4x ratio and carry valid **mclabels** on their Pod template. Each namespace is either warned, enforced or left alone.

## 📖 Glossary

- **Workload**: an `apps/v1` Deployment or StatefulSet. The workload rules read its Pod template (`spec.template`), because the Pods are what run, log and emit metrics.
- **mclabels**: the four MapColonies labels a workload's Pod template must carry: `mapcolonies.io/environment`, `mapcolonies.io/part-of`, `mapcolonies.io/owner` and `mapcolonies.io/component`.
- **Warn namespace**: a namespace in `workloadPolicies.warnNamespaces`. A violation is applied anyway, and the client sees a warning.
- **Enforced namespace**: a namespace in `workloadPolicies.enforcedNamespaces`. A violation rejects the request, unless that rule's `enforcementAction` is set to `warn` or `dryrun`.
- **Unlisted namespace**: a namespace in neither list. The workload rules don't apply there.
- **Violation trigger**: the requests the workload rules check at admission. These are a CREATE, or an UPDATE that changes the Pod template, i.e. a new revision (`helm upgrade` with changed Pod values, `kubectl rollout restart`, a new image). An UPDATE that only scales the workload or changes its own metadata is never checked, so existing non-compliant workloads keep running, scaling and being patched. Gatekeeper audit always checks every workload.
- **Exemption**: excludes one workload from one rule, in both warn and enforced namespaces. It comes from either the exemption list or the workload annotation (see below).

## 🛠️ Pod rules

Pods in `namespaces` (all namespaces when empty) are checked in **warn** mode. A violation is reported but doesn't block deploys. Everything is configurable under `constraints` in `values.yaml`.

**Required labels**
- `app.kubernetes.io/name`
- `app.kubernetes.io/instance`
- `app.kubernetes.io/version`
- `app.kubernetes.io/managed-by`
- `mapcolonies.io/part-of`
- `mapcolonies.io/owner`
- `mapcolonies.io/environment`
- `mapcolonies.io/component`
- `mapcolonies.io/criticality`

**Required annotations**
- `prometheus.io/path`
- `prometheus.io/port`
- `prometheus.io/scrape`

**Disallowed label values**
- `mapcolonies.io/environment` may not be `undefined`

## 🧱 Workload rules

Both rules check Deployments and StatefulSets in warn and enforced namespaces, on a violation trigger.

### CPU ratio (`K8sWorkloadCpuRatio`)

Every entry in `containers` and `initContainers` must have a CPU request and a CPU limit, and the limit must be **exactly 4x** the request.
- Values are compared after unit conversion, exactly, in whole nanocores. So `0.5`/`2000m`, `"1"`/`4000m` and `0.0625`/`250m` are all compliant.
- `request == limit` is a violation. Guaranteed QoS on purpose needs an exemption.
- Init containers are checked. Ephemeral containers and memory are not.
- There is one violation per offending container. The message names the container, the actual request and limit, and the expected limit.

### mclabels (`K8sWorkloadMcLabels`)

The Pod template's labels (`spec.template.metadata.labels`) must carry:
- `mapcolonies.io/owner`: one of `vector`, `raster`, `3d`, `app`, `dem`, `infra`, `common`, `automation`
- `mapcolonies.io/environment`: non-empty and not `undefined`
- `mapcolonies.io/part-of`: non-empty
- `mapcolonies.io/component`: non-empty

Labels on the workload's own metadata don't count. `gis-domain`, `alloy-api-logs` and `criticality` are not required by this rule. There is one violation per workload, and it lists every missing or invalid label.

### Exemptions

A workload is exempt from a rule if either of these applies:
1. **It has an entry in the exemption list** (`workloadPolicies.exemptions`), set in site-values and reviewed by PR.
2. **Its own metadata** (not the Pod template) carries a non-empty `mapcolonies.io/exempt-cpu-ratio` or `mapcolonies.io/exempt-mclabels` annotation, whose value is the reason. An empty value is ignored. Adding the annotation doesn't change the Pod template, so it doesn't restart Pods.

## ⚙️ Values

```yaml
workloadPolicies:
  # Gatekeeper namespace globs work, e.g. "*-dev".
  warnNamespaces: []      # <rule>-warn Constraints, always enforcementAction: warn
  enforcedNamespaces: []  # <rule>-enforced Constraints, with <rule>.enforcementAction
  exemptions:
    - namespace: raster-prod      # exact match, no wildcards
      kind: Deployment            # Deployment or StatefulSet, exact match
      name: mapproxy              # exact match
      rules: [cpuRatio]           # cpuRatio, mclabels or both
      reason: Guaranteed QoS      # required
  cpuRatio:
    enabled: true
    enforcementAction: deny       # in enforced namespaces: deny, warn or dryrun
  mclabels:
    enabled: true
    enforcementAction: deny
```

- **An empty namespace list means its Constraints are not rendered.** This differs from Gatekeeper, where an empty list matches every namespace. The defaults are empty lists, so the chart renders no workload Constraints until they are set.
- `<rule>.enforcementAction` lets site-values downgrade one rule in enforced namespaces, e.g. to `warn`, without moving namespaces between the lists.
- **Rendering fails** on an exemption entry without a `namespace`, `kind`, `name` or `reason`, on an unknown kind or rule, or on an `enforcementAction` other than `deny`, `warn` or `dryrun`.
- `<rule>.enabled: false` removes that rule's ConstraintTemplate and Constraints.

### Deploy alerts

```yaml
deployAlerts:
  enabled: false                    # off by default: no ConfigMap is rendered
  includeEnforcedNamespaces: false  # also alert in workloadPolicies.enforcedNamespaces
  defaultTeam: infra                # alert_team of namespaces namespaceTeams does not mention

namespaceTeams:                     # namespace -> owning team (exact name or glob)
  - { namespace: raster-dev, team: raster }
  - { namespace: dem-dev, team: 3d }
  - { namespace: gateway-dev, silence: true }   # mapped to no team: no alert
```

- **What it renders.** With `deployAlerts.enabled`, a ConfigMap `<release>-deploy-alerts` labelled `mapcolonies.io/grafana-alerts` holds a Grafana-managed alert rule on the Loki datasource (uid `loki`). It counts the `workload-*` violation lines Gatekeeper logs at admission over 10 minutes and fires once per namespace, kind, name, Constraint, deploying user and message. Redeploying the same broken workload in that window gives no extra alert. Dedup tradeoff: the spec's key is namespace, kind, name and Constraint, but the rule also groups by `request_username` and `msg`. Grafana builds alert annotations only from the query's labels, so dropping them from the grouping would drop the deploying user and the rule message from the alert text. The cost is one extra alert when the same workload breaks the same Constraint with a different message or from a different user within 10 minutes. The `description` annotation is Gatekeeper's message without its `denied admission: ` prefix (with or without a leading `Gatekeeper `) (these are warnings, the workload was admitted) and without its trailing `To exempt this workload...` sentence, which the `how_to_exempt` annotation says. Labels: `severity=warning`, `alert_team=<owning team>`, `notify_resolved=false` (Grafana routes these to contact points that send no "resolved" message).
- **Team mapping.** `namespaceTeams` maps an exact namespace or glob to a team. The chart renders one rule per mapped namespace, each carrying its `alert_team`, because a Loki query can't take a team label from a lookup. An exact namespace beats a glob; among globs the first listed wins. A namespace no entry matches goes to `defaultTeam`, so nothing is dropped silently. `silence: true` maps a namespace to no team: it is excluded from every rule, so it raises no alert. The value names teams, not channels, and is not specific to alerts, so other consumers can read it.
- **Scope.** The namespace filter is built from `workloadPolicies.warnNamespaces`, with `*` and `?` globs turned into a regex. `enforcedNamespaces` are added only with `includeEnforcedNamespaces: true`.
- **Annotations are plain text** (workload and rule, the rule's message, the deploying user, how to exempt), so they read the same in Slack or Teams.
- **Rendering fails** if no namespace is in scope, if a namespace has characters other than `a-z`, `0-9`, `-`, `*`, `?`, if `defaultTeam` or a mapped `team` is not a plain team name, or if a `namespaceTeams` entry sets both or neither of `team` and `silence`.
- **Prerequisites outside this chart.** `gatekeeper.logDenies: true`, the Alloy log pipeline collecting `gatekeeper-system` (keeping only `workload-*` violations), and Grafana's alert sidecar searching the release namespace (`grafana.sidecar.alerts.searchNamespace`).

### Daily report

A CronJob that posts one summary per team, on a schedule, of every Deployment and StatefulSet that breaks a workload rule today (MAPCO-11867). The deploy alerts above only see deploys; this sees the whole backlog. It also pushes each run to Loki, for the workload policy dashboard.

```yaml
dailyReport:
  enabled: false                 # off by default: nothing is rendered
  namespace: ""                  # required; must hold webhooksSecret (dev: infra-dev)
  schedule: "30 7 * * 0-4"       # UTC, Sun-Thu 07:30
  dryRun: false                  # log the messages instead of posting; Loki still gets the run
  postWhenClean: false           # also post "no violations" to clean teams
  webhooksSecret: grafana-webhooks-external   # <TEAM>_WEBHOOK keys, 3d -> TEAM_3D_WEBHOOK
  maxNamesPerRule: 10            # names per namespace and rule, then "+N more"
  maxMessageChars: 3500          # longer messages shrink to 5 names, then to counts only
  dashboardUrl: ""               # required; linked from every message
  readmeUrl: <this README>       # "How to fix or exempt" link
  environment: ""                # required; mapcolonies.io/environment of the job Pod
  constraintKinds: [K8sWorkloadCpuRatio, K8sWorkloadMcLabels]
  gator: {version: v3.22.0, url: <release tarball>, sha256: <pinned>}
  image: {registry: docker.io, repository: library/python, tag: 3.13-alpine@sha256:<pinned>}
  resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {cpu: 200m, memory: 256Mi}}   # 1:4
  loki: {pushUrl: "", job: gatekeeper-workload-report}   # pushUrl required
  alerts: {enabled: true, checkDays: [0, 1, 2, 3, 4], checkFromHour: 9, checkToHour: 16, lookback: 9h}
```

- **What it renders.** In `dailyReport.namespace`: a ConfigMap with `report.py` (`files/daily-report/report.py`) and `teams.json`, a ServiceAccount, and a CronJob (`concurrencyPolicy: Forbid`, `backoffLimit: 0`, one Python container, read-only root, non-root, all capabilities dropped). Cluster-wide: a ClusterRole and ClusterRoleBinding with `get`/`list` on Deployments, StatefulSets, Namespaces, the Constraints of `constraintKinds` and their ConstraintTemplates. No Secrets, no `pods/log`, no write verbs. In the release namespace: the rule ConfigMap below.
- **How it counts.** The job downloads the pinned gator tarball and checks its sha256. It reads the live ConstraintTemplates and Constraints of `constraintKinds`, the Namespaces, and every workload kind those Constraints match, keeping only what the rules read (no env, images or volumes). Then it runs `gator test` on them. Every Constraint runs as `warn` under its own name, so gator does not stop at a deny. No Rego is copied: the result is what Gatekeeper's audit sees, exemptions included. A workload counts once per rule even when a warn and an enforced Constraint both match it. The CPU rule counts workloads, with the offending containers in brackets. mclabels counts workloads, split into **missing** (a label is absent) and **invalid** (empty, an owner outside the list, `environment=undefined`). A workload can be both.
- **Routing.** `namespaceTeams` again: exact names before globs, the first match wins, and an unmatched namespace goes to `deployAlerts.defaultTeam`. `silence: true` namespaces are not posted anywhere. They are pushed to Loki under team `silenced`, so the dashboard shows them.
- **Message.** One per team with violations. Per namespace it gives the counts per rule, then up to `maxNamesPerRule` names per rule, sorted (StatefulSets as `sts/<name>`), then "+N more", then a link to the dashboard for that team and run.
- **Failures.** Every failure is told to `defaultTeam` and makes the job exit 1. The run status says what happened:
  - `skipped` (no report was sent): an API error, a configured kind with no Constraint, a gator download or sha256 failure, gator exiting non-zero, printing a warning, timing out or printing something that is not JSON. Any unexpected error (a bug, `/work` not writable) is also `skipped`, with the exception's type and text as the reason and the traceback in the Pod log.
  - `partial` (some reports went out): a team whose webhook is missing or malformed, or whose post failed (non-2xx, a Slack error body, a timeout). The other teams are still posted. A missing webhook fails its team in a `dryRun` too, so a dry run shows a missing Secret key in its status (`posted` then lists the teams that would have been posted). A failed Loki push (an error or a non-2xx answer) is also `partial`; the run line in the Pod log then says so.
  - Audit check, per Constraint: when its audit is less than 2 h old and gator's count differs from its `status.totalViolations` by more than max(5, 10%) (or gator finds 0 and audit doesn't), the run is `partial` with a "gator N vs audit M" line. A Constraint with an older (or no) audit is skipped, not an error: it is left out of the rule's `auditCheck` counts and named in the Pod log, and the rule's `auditCheck` is `skipped` when none of its Constraints had a fresh audit.
  - Error texts never contain a URL.
- **Grafana rules** (`alerts.enabled`; folder Gatekeeper, `alert_team=<defaultTeam>`, `notify_resolved=false`):
  - `gk-daily-report-missing` fires when no run reached Loki within `lookback` (no data counts as no run). It is checked only on `checkDays` (0 = Sunday) between `checkFromHour` and `checkToHour` UTC, because the stack runs only part of the day and a plain "last run is old" rule would fire every morning. It is one Grafana rule over two datasources: Loki counts runs, Prometheus `hour()`/`day_of_week()` gives the check window, and a math expression combines them. `lookback` must reach back to the scheduled time from `checkToHour` and stay shorter than the gap to the previous run (07:30 run, 09:00-16:00 check: `9h`). A query error is not a missing run: the rule keeps its last state (`execErrState: KeepLast`), so Loki or Prometheus not being ready when the stack starts, or a transient error, alerts nobody and the check window and `for` still hold. A Loki that is down when the job runs is reported by the job itself (the push fails, the run is `partial` and infra is told). On the day the rules are first deployed no run is in Loki yet, so a deploy inside the check window fires the rule 15 minutes later: deploy outside the window, or start a run (`kubectl create job --from=cronjob/...`, a dry run counts) within 15 minutes of the deploy.
  - `gk-daily-report-failed` fires on a run line with status `partial` or `skipped` in the last 3 h. This also covers a failed post to the infra channel itself.
- **Decisions.**
  - "Daily" means the Israeli work week, Sun-Thu (the job runs at 07:30 UTC).
  - mclabels reports every violation of the deployed rule, split into missing and invalid.
  - Silenced namespaces appear on the dashboard only.
  - gator is downloaded at run time (point `gator.url` at a mirror if github.com is not reachable).
- **Rendering fails** when the report is enabled without `namespace`, `schedule`, `webhooksSecret`, `dashboardUrl`, `environment` or `loki.pushUrl`. It also fails on a URL that is not http(s) (`dashboardUrl`, `readmeUrl`, `loki.pushUrl`, `gator.url`), `environment: undefined`, a `gator.sha256` that is not 64 hex characters, a `gator.url` that does not contain `gator.version` (a mirror may have it in the file name only), `constraintKinds` that is not a list or has a malformed entry, a `maxNamesPerRule` or `maxMessageChars` that is not a number >= 0, or a bad `alerts` window (`lookback`, `checkDays`, the hours).

**Loki contract** (shared with the workload policy dashboard). Stream labels: `{job="<loki.job>", run_id="<UTC start, e.g. 2026-10-26T07:30:04Z>", team="<team|silenced|_run>", namespace="<namespace|_team|_run>"}`. Every line of a run has the run's start time plus 1 ns per line. The line is JSON, by `type`:
- `summary` (one per namespace and rule with violations): `{"type":"summary","rule":"cpuRatio","workloads":43,"containers":56}`, and for mclabels `{"type":"summary","rule":"mclabels","workloads":55,"missing":54,"invalid":1}`.
- `team_total` (stream `namespace="_team"`, one per team and rule, every run, zeros included; teams are `namespaceTeams` teams, `defaultTeam` and `silenced`): `{"type":"team_total","rule":"cpuRatio","workloads":0,"containers":0,"missing":0,"invalid":0}`.
- `violation` (one per workload and rule): `{"type":"violation","rule":"mclabels","kind":"Deployment","workload":"api","containers":[],"problems":{"missing":["mapcolonies.io/owner"],"invalid":[]},"msg":"<gator message(s)>"}`.
- `run` (stream `team="_run", namespace="_run"`): `{"type":"run","status":"ok|partial|skipped","reason":"...","posted":["3d"],"failed":[],"dryRun":false,"auditCheck":{"cpuRatio":{"gator":157,"audit":157},"mclabels":"skipped"},"gator":"v3.22.0","schedule":"30 7 * * 0-4"}`. In a dry run `posted` lists the teams that would have been posted. A rule's `auditCheck` is `"skipped"` when the run was skipped or none of its Constraints had a fresh audit, and `{"gator":N,"audit":M}` otherwise. When only some of a rule's Constraints had a fresh audit, `gator`/`audit` cover those only, and the Pod log names the others ("audit check: <rule>: no fresh audit, not compared: ...").

**Run it locally** (read-only; posts nothing, and pushes nothing while `LOKI_URL` is unset). Without `<TEAM>_WEBHOOK` env vars every team is reported as failed and the run ends `partial`; set them to any value (nothing is posted) to see an `ok` run:
```bash
cd charts/gatekeeper-constraints   # .bin/gator is downloaded by make test
helm template gatekeeper-constraints . -f <site-values dev.yaml> --set dailyReport.enabled=true \
  --set dailyReport.namespace=infra-dev --set dailyReport.environment=dev \
  --set dailyReport.dashboardUrl=https://grafana.example/d/x --set dailyReport.loki.pushUrl=http://unused/ \
  -s templates/daily-report.yaml | sed -n 's/^  teams.json: //p' \
  | python3 -I -c 'import json,sys; sys.stdout.write(json.loads(sys.stdin.read()))' > /tmp/teams.json
kubectl proxy --port=8001 &
KUBE_API=http://127.0.0.1:8001 python3 -I files/daily-report/report.py --from-cluster --dry-run \
  --teams /tmp/teams.json --gator .bin/gator --work "$(mktemp -d)"
kill %1
```
gator reads `<work>/in`: a rerun with the same `--work` replaces the files the last run wrote there, and any other file in it skips the run. `--from-files DIR` reads raw API JSON instead, one file per API path (`/apis/apps/v1/deployments` becomes `apis_apps_v1_deployments.json`), as in `tests/daily-report/fixtures/api`. To check a deployed job without posting, set `dryRun: true` and run `kubectl -n <namespace> create job --from=cronjob/<release>-daily-report <name>`. The messages are in the Pod log.

## 📝 Operational notes

- `helm upgrade --force` does not bypass the workload rules. Its delete-and-recreate goes through admission as a CREATE.
- Gatekeeper is scaled down at night and **fails open**. While it is down, nothing is checked at admission. Audit catches what slipped through once it is back.

## 🔍 See violations

- In the **OCP console**, open the `Constraint` resource under the `CustomResourceDefinitions` tab.
- Or with the CLI:
  ```bash
  kubectl get constraints
  kubectl get K8sRequiredLabels.require-pod-labels -o yaml
  kubectl get K8sRequiredAnnotations.require-pod-annotations -o yaml
  kubectl get K8sDisallowedLabelValues.disallow-pod-label-values -o yaml
  kubectl get K8sWorkloadCpuRatio -o yaml
  kubectl get K8sWorkloadMcLabels -o yaml
  ```

## 🧪 Tests

```bash
make -C charts/gatekeeper-constraints test
```

This renders the chart with `tests/values.yaml` and runs the gator Suites in `tests/suites` against the sample objects in `tests/objects`. gator is pinned to the wrapped Gatekeeper version and downloaded into `.bin/`. The target also runs these checks:
- `tests/deploy-alerts.sh`: `helm template` assertions on the deploy-alert ConfigMap (off by default, namespace scope, labels, plain-text annotations, failure on empty scope).
- `tests/gator-test/<case>`: renders the chart with the case's values, runs its objects through `gator test` and checks the outcome named in the case's `expect` file: `nothing`, `warnings-only` or `denials`. These cases cover which Constraints get rendered and with which enforcement action, e.g. that an empty namespace list really renders no Constraint.
- `tests/render-failures/<values>`: checks that rendering fails with the error named on the file's first line (exemptions, enforcement action, the deployAlerts / namespaceTeams validation, and the dailyReport validation).
- `tests/daily-report.sh`: `helm template` assertions on the daily report. Covers: off by default; where each object lands; one optional `secretKeyRef` per team (defaultTeam included) and no literal webhook; `get`/`list`-only RBAC that follows `constraintKinds` (ConstraintTemplates: `get` on those names only); CPU limit = 4x request; the CronJob wiring (mounts, `--work` on an emptyDir, ServiceAccount, no retry); every value reaching the job env; the gator version matching the Makefile and the wrapped Gatekeeper; `teams.json` order; the two Grafana rules.
- `tests/daily-report/test_report.py` (stdlib `unittest`): `report.py` on raw API fixtures with fake gator, webhook and Loki endpoints. Covers: projection, pagination, counting, missing vs invalid, routing, message capping, every failure path, `dryRun`, and the Loki payload. It also pins the Rego message formats that `report.py` parses.
- `tests/daily-report/parity.sh`: runs gator on `tests/objects` as they are and on `report.py`'s projection of the same objects served as raw API JSON, and fails if the results differ. It also fails if `tests/daily-report/fixtures` is stale (`make daily-report-fixtures` rewrites it).
- `tests/daily-report/job-pod.sh`: the job's own Pod passes every rule of this chart (Pod labels, annotations, 1:4 CPU, mclabels).

The PR workflow runs the same target when files under this chart change.
