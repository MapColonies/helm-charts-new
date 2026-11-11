# grafana

Wraps the community Grafana chart and provisions alerting for the teams in
`grafana.alertingTeamsWebhooks` (webhook setup: see the comments in `values.yaml`).

## Grafana 13 and MapLibre

The shared Grafana image (`image.tag` in `values.yaml`) contains Grafana `13.2.5` and the
`mapcolonies-maplibre-panel` plugin. The chart permits this unsigned plugin by ID
through `grafana.grafana.ini.plugins.allow_loading_unsigned_plugins`. Consumers
overriding that setting must preserve this ID to load MapLibre.

### Upgrade and rollback

Before upgrading each environment, verify the database host and database name
from the running Grafana instance. Stop all Grafana replicas and back up that
exact database, together with the previous image, chart values, provisioning and
secrets (including the Grafana encryption key). Grafana 13 applies database and
stored-dashboard migrations; starting the old image is not a database rollback.

The chart defaults to `grafana.deploymentStrategy.type: Recreate` to stop the old
pod before starting the new version against the same database. Preserve this
strategy in environment overrides and disable automatic Helm rollback for the
migration window. If validation fails, stop the upgraded replicas, restore a
verified pre-upgrade database backup, and only then start the previous image with
its previous configuration and secrets.

Validate login, existing dashboards, data-source queries, MapLibre, provisioning
and alerting after deployment. Newer community chart dependencies require
Kubernetes 1.25 or later; this change retains Grafana chart `10.7.0` and
`openshift-routes` `1.0.2` for existing cluster compatibility.

## Alert notifications

Per team, three contact points on the same webhook (`${<TEAM>_WEBHOOK}`), and a route under
`alert_team = "<team>"` that picks one of them. The first matching child route wins:

| Alert labels | Contact point | Messages |
| --- | --- | --- |
| `notify_resolved="false"` and any `alert_group` | `<team>-alerts-digest` | one digest per team and `alert_group`: grouped by `[alert_team, alert_group]`, first after 1m, follow-ups at most every 5m, repeated after 12h; no "resolved" message |
| `notify_resolved="false"` | `<team>-alerts-no-resolve` | one message per alert (`group_by: ['...']`); no "resolved" message |
| anything else | `<team>-alerts` | Grafana's default layout, with "resolved" messages |

Message layouts (`files/notification-templates.yaml`, set on Slack and Teams receivers only):

- `no_resolve_notification`: per alert, `description`, then every other annotation as
  `Name: value` (except `digest_*`), and its Silence link.
- `digest_notification`: title from the first alert's `digest_title` annotation (else its
  alertname) and the alert count; one line per firing alert from `digest_line` (else
  `summary`), at most 25 with a "showing the first 25 of N" note; the first alert's
  `digest_footer` once; one Silence link prefilled with the group labels (narrow it before
  saving).

To send a rule's alerts as a digest, give it the labels `alert_team`, `notify_resolved: "false"`
and `alert_group: <name>`, and the `digest_*` annotations. Example: the Gatekeeper deploy
alerts (`gatekeeper-constraints`, `alert_group=gatekeeper-deploy`).

Alertmanager resends the whole group when alerts join it: a digest that comes after the first
one lists the alerts already sent too.

## Tests

No CI; run by hand from `charts/grafana` (after `helm dependency build`):
`for t in tests/*.sh; do bash "$t"; done`
