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

- **What it renders.** With `deployAlerts.enabled`, a ConfigMap `<release>-deploy-alerts` labelled `mapcolonies.io/grafana-alerts` holds a Grafana-managed alert rule on the Loki datasource (uid `loki`). It counts the `workload-*` violation lines Gatekeeper logs at admission over 10 minutes and fires once per namespace, kind, name, Constraint, deploying user and message. Redeploying the same broken workload in that window gives no extra alert. Dedup tradeoff: the spec's key is namespace, kind, name and Constraint, but the rule also groups by `request_username` and `msg`. Grafana builds alert annotations only from the query's labels, so dropping them from the grouping would drop the deploying user and the rule message from the alert text. The cost is one extra alert when the same workload breaks the same Constraint with a different message or from a different user within 10 minutes. The `description` annotation is Gatekeeper's message without its `Gatekeeper denied admission: ` prefix (these are warnings, the workload was admitted) and without its trailing `To exempt this workload...` sentence, which the `how_to_exempt` annotation says. Labels: `severity=warning`, `alert_team=<owning team>`, `notify_resolved=false` (Grafana routes these to contact points that send no "resolved" message).
- **Team mapping.** `namespaceTeams` maps an exact namespace or glob to a team. The chart renders one rule per mapped namespace, each carrying its `alert_team`, because a Loki query can't take a team label from a lookup. An exact namespace beats a glob; among globs the first listed wins. A namespace no entry matches goes to `defaultTeam`, so nothing is dropped silently. `silence: true` maps a namespace to no team: it is excluded from every rule, so it raises no alert. The value names teams, not channels, and is not specific to alerts, so other consumers can read it.
- **Scope.** The namespace filter is built from `workloadPolicies.warnNamespaces`, with `*` and `?` globs turned into a regex. `enforcedNamespaces` are added only with `includeEnforcedNamespaces: true`.
- **Annotations are plain text** (workload and rule, the rule's message, the deploying user, how to exempt), so they read the same in Slack or Teams.
- **Rendering fails** if no namespace is in scope, if a namespace has characters other than `a-z`, `0-9`, `-`, `*`, `?`, if `defaultTeam` or a mapped `team` is not a plain team name, or if a `namespaceTeams` entry sets both or neither of `team` and `silence`.
- **Prerequisites outside this chart.** `gatekeeper.logDenies: true`, the Alloy log pipeline collecting `gatekeeper-system` (keeping only `workload-*` violations), and Grafana's alert sidecar searching the release namespace (`grafana.sidecar.alerts.searchNamespace`).

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
- `tests/render-failures/<values>`: checks that rendering fails with the error named on the file's first line (exemptions, enforcement action, and the deployAlerts / namespaceTeams validation).

The PR workflow runs the same target when files under this chart change.
