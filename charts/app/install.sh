#!/usr/bin/env bash

set -euo pipefail

# Keep dependencies fresh for all app-related umbrella subcharts.
helm dependency update charts/app
helm dependency update charts/common
helm dependency update charts/extractable

cat <<'EOF'
Dependencies were updated.

This repository migrates deployment flow from direct `helm install` to `helmfile`.
Use your helmfile environment to deploy this chart and compose values from:
- global-values.yaml
- global-values-overrides.yaml
- charts/common/global-values.yaml
- charts/common/global-values-overrides.yaml
- charts/app/global-values.yaml
- charts/app/global-values-overrides.yaml
- values.yaml or values-dev-*.yaml
EOF
