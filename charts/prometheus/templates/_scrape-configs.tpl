{{/*
Entry point for every scrape job this chart generates.

The upstream subchart builds `scrape_configs` from three sources and passes only the last —
`extraScrapeConfigs` — through `tpl`, so that key is the chart's single seam. values.yaml sets
it to an `include` of this template; everything generated is composed from here.

Two consequences, both documented in README.md:

  - `tpl` runs in the *subchart's* context, so `.Values` here is the subchart's values and
    every input must live under the `prometheus` key. The umbrella's top level is unreachable.
  - Whatever the other two upstream sources contribute renders *before* this. Prometheus does
    not care about job order, but comparisons against previously rendered output must be
    order-insensitive.

The upstream template applies `indent 4` to the result, so this must emit a YAML sequence
starting at column 0.

Composition order is fixed: self-scrape, pod service discovery, service service discovery,
blackbox jobs, static jobs, raw extra jobs. Later additions append to $parts in that order.
Each part emits a YAML sequence or nothing at all; parts that emit nothing are dropped rather
than joined, so they leave no blank line between the parts that do.
*/}}
{{- define "prometheus.mapcolonies.scrapeConfigs" -}}
{{- $parts := list
      (include "prometheus.mapcolonies.scrape.selfScrape" .)
-}}
{{- $rendered := list -}}
{{- range $parts -}}
{{- with trim . -}}
{{- $rendered = append $rendered . -}}
{{- end -}}
{{- end -}}
{{- join "\n" $rendered -}}
{{- end -}}
