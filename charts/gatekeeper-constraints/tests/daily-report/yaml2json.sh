#!/usr/bin/env bash
# Usage: yaml2json.sh FILE...
# Prints every YAML document in the files as one line of JSON. Python's stdlib has no YAML
# parser, so this borrows Helm's (fromYaml) through a throwaway chart.
set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/templates"
printf 'apiVersion: v2\nname: yaml2json\nversion: 0.0.0\n' > "$tmp/Chart.yaml"
cat > "$tmp/templates/out.yaml" <<'TPL'
{{- range $f := .Values.files }}
{{- range splitList "\n---" $f }}
{{- $doc := fromYaml . }}
{{- if hasKey $doc "Error" }}{{ fail $doc.Error }}{{ end }}
{{- if $doc }}
# {{ toJson $doc }}
{{- end }}
{{- end }}
{{- end }}
TPL
args=()
i=0
for f in "$@"; do
  args+=(--set-file "files[$i]=$f")
  i=$((i + 1))
done
helm template yaml2json "$tmp" "${args[@]}" | sed -n 's/^# {/{/p'
