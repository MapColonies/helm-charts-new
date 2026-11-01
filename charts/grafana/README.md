# grafana

Wraps the community Grafana chart and provisions alerting for the teams in
`grafana.alertingTeamsWebhooks` (webhook setup: see the comments in `values.yaml`).

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
