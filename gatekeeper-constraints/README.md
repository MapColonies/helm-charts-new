# gatekeeper-constraints

Helm chart for Gatekeeper rules that make sure Pods have the right **labels** and **annotations**.

## ⚙️ What it does

- ✅ Checks Pods for required labels and annotations  
- ⚠️ Runs in **WARN (audit-only)** mode by default (shows violations, doesn’t block deploys)  
- 🔧 Fully configurable in `values.yaml`  

## 🛠️ Checks
Fully configurable in `values.yaml`  

**Annotations**
- `prometheus.io/path`
- `prometheus.io/port`
- `prometheus.io/scrape`

**Labels**
- `app.kubernetes.io/name`
- `app.kubernetes.io/instance`
- `app.kubernetes.io/version`
- `app.kubernetes.io/managed-by`
- `mapcolonies.io/part-of`
- `mapcolonies.io/owner`
- `mapcolonies.io/environment`
- `mapcolonies.io/component`

## 🔍 See Violations

- In the **OCP console** → open the `Constraint` resource under the `CustomResourceDefinitions` tab.
- Or via CLI:
  ```bash
  kubectl get K8sRequiredLabels.require-pod-labels -o yaml
  kubectl get K8sRequiredAnnotations.require-pod-annotations -o yaml
  ```
