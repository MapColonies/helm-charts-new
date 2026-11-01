#!/usr/bin/env bash
# Usage: naming.sh
# Renders an umbrella chart whose apps use blackbox-lib and this chart as a subchart (alias: blackbox), and checks
# that every prometheus.io/probe-exporter annotation (built by blackbox-lib) points to an exporter Service of this
# chart that serves the annotated prometheus.io/probe-module, and that no two resources share a name.
# The two charts build the exporter name separately, so this catches the two drifting apart.
# Needs helm and yq (mikefarah, v4).
set -euo pipefail

chart_dir=$(cd "$(dirname "$0")/.." && pwd)
lib_dir=$(cd "$chart_dir/../blackbox-lib" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

app() { # name, extra values
  mkdir -p "$tmp/$1/templates"
  cat > "$tmp/$1/Chart.yaml" <<EOF
apiVersion: v2
name: $1
version: 0.1.0
dependencies:
  - name: blackbox-lib
    version: "*"
    repository: file://$lib_dir
  - name: blackbox-exporter
    version: "*"
    repository: file://$chart_dir
    alias: blackbox
    condition: blackbox.customExporter.enabled
EOF
  cat > "$tmp/$1/templates/service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-{{ .Chart.Name }}
  annotations:
    {{- include "blackbox-lib.serviceAnnotations" . | nindent 4 }}
spec:
  ports:
    - port: 8080
EOF
  printf 'blackbox:\n  enabled: true\n  module: %s_check\n  customExporter:\n    enabled: true\n%b' "${1//-/_}" "${2:-}" > "$tmp/$1/values.yaml"
  helm dependency update --skip-refresh "$tmp/$1" > /dev/null
}

# mapproxy and mapproxy-api: both names are contained in the release name raster-mapproxy-api.
app mapproxy
app mapproxy-api
app polygon-parts "    fullnameOverride: polygon-parts-probe\n"
mkdir -p "$tmp/umbrella"
cat > "$tmp/umbrella/Chart.yaml" <<EOF
apiVersion: v2
name: umbrella
version: 0.1.0
dependencies:
  - {name: mapproxy, version: "*", repository: "file://$tmp/mapproxy"}
  - {name: mapproxy-api, version: "*", repository: "file://$tmp/mapproxy-api"}
  - {name: polygon-parts, version: "*", repository: "file://$tmp/polygon-parts"}
EOF
helm dependency update --skip-refresh "$tmp/umbrella" > /dev/null
helm template raster-mapproxy-api "$tmp/umbrella" -n raster-dev > "$tmp/out.yaml"

failed=0
dups=$(yq -N 'select(.kind) | .kind + "/" + .metadata.name' "$tmp/out.yaml" | sort | uniq -d)
if [[ -n $dups ]]; then
  echo "FAIL duplicate resources: $dups"
  failed=1
fi

checked=0
while read -r service exporter module; do
  name=${exporter%%.*}
  served=$(NAME=$name yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["blackbox.yaml"] | from_yaml | .modules | keys | .[]' "$tmp/out.yaml")
  if ! NAME=$name yq -e -N 'select(.kind == "Service" and .metadata.name == strenv(NAME))' "$tmp/out.yaml" > /dev/null 2>&1; then
    echo "FAIL $service: probe-exporter $exporter has no exporter Service"
    failed=1
  elif [[ $served != "$module" ]]; then
    echo "FAIL $service: exporter $name serves '$served', annotation asks for '$module'"
    failed=1
  else
    echo "ok   $service -> $name ($module)"
  fi
  checked=$((checked + 1))
done < <(yq -N 'select(.kind == "Service" and .metadata.annotations["prometheus.io/probe-exporter"]) |
  .metadata.name + " " + .metadata.annotations["prometheus.io/probe-exporter"] + " " + .metadata.annotations["prometheus.io/probe-module"]' "$tmp/out.yaml")

if (( checked != 3 )); then
  echo "FAIL expected 3 annotated app Services, found $checked"
  failed=1
fi
exit $failed
