# Status page dashboard builders

Generate the JSON in `../files/dashboards/status-page/` (provisioned into the Grafana
folder "Status Page" by `templates/status-page-dashboards.yaml`).

```sh
cd charts/grafana/dashboard-builders
python3 build_overview_dashboard.py ../files/dashboards/status-page/overview-status-page.json
python3 build_team_dashboard.py     ../files/dashboards/status-page/team-status-page.json
```

| Dashboard | UID | What it shows |
| --- | --- | --- |
| MapColonies Status | `at9fgw` | One tile per team (mclabels `owner`), blackbox endpoints, failing probes, uptime by team, core infra (TCP, TLS), firing alerts |
| Team Status Page | `a6j7gg` | `?var-owner=<team>`: status, customer/internal uptime, endpoints, failing probes, a row per `partOf` with a tile per `component` |

Keep the UIDs: the overview links to the team page by UID.

Everything is driven by mclabels on the `up` metric (`mapcolonies_io_owner`, `_part_of`,
`_component`, `_criticality`). A service appears automatically once its chart sets
`prometheus.enabled: true`; without `mclabels.criticality` it is shown as `unassigned`.
Customer status also fails when a `blackbox-exporter-<team>` probe fails.
