# App

Umbrella chart for Catalog App services migrated from the legacy `helm install` flow.

## Dependency build

```bash
./install.sh
```

or manually:

```bash
helm dependency update charts/app
helm dependency update charts/common
helm dependency update charts/extractable
```

## Helmfile deployment

This chart is intended to be deployed via `helmfile`.

Example `helmfile.yaml` snippet:

```yaml
releases:
	- name: app
		namespace: dem-dev
		chart: ./charts/app
		values:
			# Optional shared globals file from your platform repo/workspace:
			# - ../global.yaml
			- ./charts/app/global-values.yaml
			- ./charts/app/global-values-overrides.yaml
			- ./charts/app/charts/common/global-values.yaml
			- ./charts/app/charts/common/global-values-overrides.yaml
			- ./charts/app/charts/app/global-values.yaml
			- ./charts/app/charts/app/global-values-overrides.yaml
			- ./charts/app/values-dev-dem.yaml
		set:
			- name: global.currentSubChart
				value: catalog
```

Recommended values composition order:

1. `../global.yaml`
2. `global-values.yaml`
3. `global-values-overrides.yaml`
4. `charts/common/global-values.yaml`
5. `charts/common/global-values-overrides.yaml`
6. `charts/app/global-values.yaml`
7. `charts/app/global-values-overrides.yaml`
8. `values.yaml` or an environment file such as `values-dev-dem.yaml`

For exact chart location and values list used by automation, see `deployment.json`.
