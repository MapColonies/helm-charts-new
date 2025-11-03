# monitoring

## Intro

This is a collection of charts of the monitroing infrastructure

## prerequisites

1. Create a service account
```bash
oc create sa monitoring
```
2. Add the service account to the anyuid SCC (may require cluster admin):
```bash
oc adm policy add-scc-to-user anyuid -z monitoring
```

## Installation


```bash
helm upgrade --install --history-max 2 infra-monitoring -f infra-values.yaml --render-subchart-notes .
```
