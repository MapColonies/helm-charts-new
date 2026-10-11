# gatekeeper-constraints

Helm chart for the Gatekeeper rules of the cluster. It wraps upstream Gatekeeper and adds:

- **Pod rules**: Pods need the right **labels** and **annotations**. These rules only warn.
- **Workload rules**: Deployments and StatefulSets must set CPU requests and limits at a 4x ratio and carry valid **mclabels** on their Pod template. Each namespace is either warned, enforced or left alone.

## 📖 Glossary

- **Workload**: an `apps/v1` Deployment or StatefulSet. The workload rules read its Pod template (`spec.template`), because the Pods are what run, log and emit metrics.
- **mclabels**: the four MapColonies labels a workload's Pod template must carry: `mapcolonies.io/environment`, `mapcolonies.io/part-of`, `mapcolonies.io/owner` and `mapcolonies.io/component`.
- **Warn namespace**: a namespace in `workloadPolicies.warnNamespaces`. A violation is applied anyway, and the client sees a warning.
- **Enforced namespace**: a namespace in `workloadPolicies.enforcedNamespaces`. A violation rejects the request.
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
  warnNamespaces: []      # warn Constraints (enforcementAction: warn)
  enforcedNamespaces: []  # deny Constraints (enforcementAction: deny)
  exemptions:
    - namespace: raster-prod      # exact match, no wildcards
      kind: Deployment            # Deployment or StatefulSet, exact match
      name: mapproxy              # exact match
      rules: [cpuRatio]           # cpuRatio, mclabels or both
      reason: Guaranteed QoS      # required
  cpuRatio:
    enabled: true
  mclabels:
    enabled: true
```

- **An empty namespace list means its Constraints are not rendered.** This differs from Gatekeeper, where an empty list matches every namespace. The defaults are empty lists, so the chart renders no workload Constraints until they are set.
- **Rendering fails** on an exemption entry without a `namespace`, `kind`, `name` or `reason`, or with an unknown kind or rule.
- `<rule>.enabled: false` removes that rule's ConstraintTemplate and Constraints.

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
- `tests/no-violations/<case>`: renders the chart with the case's values and checks that its objects get no violation at all, e.g. that an empty namespace list really renders no Constraint.
- `tests/render-failures/<values>`: checks that rendering fails with the error named on the file's first line.

The PR workflow runs the same target when files under this chart change.
