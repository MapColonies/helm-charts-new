{{/*
Prometheus' self-scrape job, behind its own enable flag so that a site with an external
meta-monitoring arrangement is not double-scraped:

  prometheus.mapcolonies.scrape.selfScrape.enabled   bool, default true

The flag defaults to on in the template as well as in values.yaml, so the job survives a site
that nulls an ancestor key. The parenthesised chain tolerates a nil at any level — under a
subchart key a nulled map arrives as a live nil rather than being dropped, which a flat `dig`
over `.Values` would fail on. `dig` reads the flag itself rather than `default`, because
`default` would read an explicit `false` as absent and turn the job back on.
*/}}
{{- define "prometheus.mapcolonies.scrape.selfScrape" -}}
{{- $selfScrape := ((.Values.mapcolonies).scrape).selfScrape | default dict -}}
{{- if dig "enabled" true $selfScrape }}
- job_name: prometheus
  static_configs:
    - targets:
        - localhost:9090
{{- end }}
{{- end -}}
