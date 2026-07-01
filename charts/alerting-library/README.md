# alerting-library

A Helm library chart for generating Grafana Unified Alerting ConfigMaps.

## Usage

In your application chart, add this library as a dependency in `Chart.yaml`:
<!-- x-release-please-start-version -->
```yaml
dependencies:
  - name: alerting-library
    version: 0.0.1
    repository: oci://acrarolibotnonprod.azurecr.io/helm/infra
```
<!-- x-release-please-end-version -->

In your `templates/alerts.yaml`, use the helper to generate the ConfigMap:

```yaml
{{- if .Values.alerts.enabled }}
{{ include "alerting-library.configmap" . }}
{{- end }}
```

## Values Schema

You can configure alerts in your application's `values.yaml` under the `alerts` section:

```yaml
alerts:
  enabled: true
  team: infra
  folder: "My App Alerts"
  rules:
    - name: AppIsDown
      expr: up{job="my-app"} == 0
      severity: critical
      summary: "My App is down"
      for: "5m"
      description: "My app has been down for 5 minutes."
```
