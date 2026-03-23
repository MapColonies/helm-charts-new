# Openshift Routes Chart

A Helm chart for creating OpenShift Routes with flexible configuration options.

## Overview

This chart simplifies the deployment of OpenShift Route objects, supporting multiple routes with customizable TLS settings, timeouts, and annotations.

## Usage

### Basic Example

Create a route pointing to an existing service:

```yaml
routes:
  - name: my-app-route
    service:
      name: my-app-service
      port: 8080
    host: my-app.example.com
    tls:
      termination: edge
```

### Multiple Routes

Define multiple routes in a single deployment:

```yaml
routes:
  - name: api-route
    service:
      name: api-service
      port: 3000
    host: api.example.com

  - name: web-route
    service:
      name: web-service
      port: 80
    host: www.example.com
    path: /web
```

### Global Configuration

Apply common settings to all routes:

```yaml
global:
  namePrefix: "prod"
  commonLabels:
    environment: production
  commonAnnotations:
    managed-by: "helm"

routes:
  - name: service-route
    service:
      name: my-service
      port: 8080
```

## Configuration

| Key | Description | Default |
|-----|-------------|---------|
| `routes[].name` | Route name (required) | — |
| `routes[].service.name` | Target service name (required) | — |
| `routes[].service.port` | Target service port | — |
| `routes[].host` | Route hostname | "" |
| `routes[].path` | Route path | "" |
| `routes[].tls.termination` | TLS termination type (`edge`, `passthrough`, `reencrypt`) | `edge` |
| `routes[].tls.insecureEdgeTerminationPolicy` | Insecure policy (`Redirect`, `Allow`, `None`) | `Redirect` |
| `routes[].timeout.enabled` | Enable request timeout | `false` |
| `routes[].timeout.duration` | Timeout duration (e.g., `1m`, `30s`) | — |
| `global.namePrefix` | Prefix for all route names | "" |
| `global.commonLabels` | Labels applied to all routes | `{}` |
| `global.commonAnnotations` | Annotations applied to all routes | `{}` |

## Installation

### Standalone Deployment

```bash
helm install my-routes ./openshift-routes -f values.yaml
```

### As a Dependency

To use this chart as a dependency in another chart, add it to your `Chart.yaml`:

<!-- x-release-please-start-version -->
```yaml
dependencies:
  - name: openshift-routes
    version: "1.0.2"
    repository: "file://../routes"
```
<!-- x-release-please-end-version -->

Then update dependencies:

```bash
helm dependency update
```

In your parent chart's `values.yaml`, pass route configuration:

```yaml
openshift-routes:
  routes:
    - name: my-app-route
      service:
        name: my-app-service
        port: 8080
      host: my-app.example.com
```

Access the routes values in your templates using `{{ .Values.openshift-routes.routes }}`.

## Requirements

- Kubernetes 1.19+
- OpenShift 4.x
