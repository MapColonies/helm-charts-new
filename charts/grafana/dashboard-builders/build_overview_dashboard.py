"""Build the MapColonies overview status page (design doc: teams row, infra row, alerts row)."""
import json, sys
from failing_probes import failing_probes_panel

DS = {"type": "prometheus", "uid": "${Site}"}
OWN, CRIT, PART, COMP, SVC = ("mapcolonies_io_owner", "mapcolonies_io_criticality",
                              "mapcolonies_io_part_of", "mapcolonies_io_component",
                              "app_kubernetes_io_name")
TEAM_DASH = "/d/a6j7gg/team-status-page-beta"
UPSEL = f'up{{{OWN}!=""}}'

# ---- team status (same 4-state logic as the team template, grouped by owner) ----
ALL = f"group by ({OWN}) ({UPSEL})"


PROBE_BY_OWNER = (f'min by ({OWN}) (label_replace(probe_success{{job=~"blackbox-exporter-.*", job!="blackbox-exporter-tcp"}}, '
                  f'"{OWN}", "$1", "job", "blackbox-exporter-([a-z0-9]+).*"))')


def crit_min(c):
    up_part = f'min by ({OWN}) (max by ({OWN}, {SVC}) (up{{{OWN}!="", {CRIT}="{c}"}}))'
    if c == "customer":  # customer = customer-labelled services AND blackbox endpoint probes
        up_part = (f'min by ({OWN}) (label_replace({up_part}, "src", "up", "", "") or '
                   f'label_replace({PROBE_BY_OWNER}, "src", "probe", "", ""))')
    return f'({up_part} or {ALL})'


STATUS = (f"{crit_min('customer')} * (0.25 + 0.25 * {crit_min('internal')} * "
          f"(1 + 2 * min by ({OWN}) ({UPSEL})))")


def fill(inner):
    return (f'label_replace(label_replace({inner}, "{SVC}", "unnamed", "{SVC}", ""), '
            f'"{CRIT}", "unassigned", "{CRIT}", "")')


BY = f"{OWN}, {CRIT}, {PART}, {COMP}, {SVC}"
SVC_UP = (f"(max by ({BY}) ({fill(UPSEL)}) or on ({BY}) "
          f"((0 * group by ({BY}) ({fill('last_over_time(' + UPSEL + '[10m])')})) and on () (count(up) > 0)))")
UPTIME = f"avg by ({OWN}, {CRIT}) (avg_over_time({SVC_UP}[$__range:$__interval])) * 100"

PROBES = ('min by (team) (label_replace(probe_success{job=~"blackbox-exporter-.*", job!="blackbox-exporter-tcp"}, '
          '"team", "$1", "job", "blackbox-exporter-([a-z0-9]+).*"))')
TCP = 'probe_success{job="blackbox-exporter-tcp"}'
CERTS = ('min by (host) (label_replace((probe_ssl_earliest_cert_expiry - time()) / 86400, '
         '"host", "$1", "instance", "https?://([^/:?]+).*"))')
FIRING = 'ALERTS{alertstate="firing"}'
ALERTS_BY_SEV = f'count by (severity) ({FIRING})'
ALERTS_TABLE = (f'max by (alertname, severity, alert_team, namespace) '
                f'(ALERTS_FOR_STATE and ignoring (alertstate) {FIRING}) * 1000')

STATUS_MAP = [{"type": "value", "options": {
    "1": {"text": "Operational", "color": "green", "index": 0},
    "0.5": {"text": "Degraded", "color": "orange", "index": 1},
    "0.25": {"text": "Internal Outage", "color": "red", "index": 2},
    "0": {"text": "Customer Outage", "color": "dark-red", "index": 3}}}]
UPDOWN_MAP = [{"type": "value", "options": {
    "1": {"text": "Up", "color": "green", "index": 0},
    "0": {"text": "Down", "color": "red", "index": 1}}}]
TH_GREEN = {"mode": "absolute", "steps": [{"color": "green", "value": None}]}
TH_UPTIME = {"mode": "absolute", "steps": [{"color": "red", "value": None},
                                           {"color": "orange", "value": 95},
                                           {"color": "green", "value": 99.5}]}


def target(expr, legend="", instant=True, fmt="time_series", ref="A"):
    return {"datasource": DS, "editorMode": "code", "expr": expr, "legendFormat": legend,
            "refId": ref, "instant": instant, "range": not instant, "format": fmt}


def stat(pid, title, pos, expr, legend, mappings=None, thresholds=None, unit="", links=None,
         desc="", text_mode="value_and_name", decimals=None):
    return {"id": pid, "type": "stat", "title": title, "description": desc, "datasource": DS,
            "gridPos": pos, "targets": [target(expr, legend)],
            "fieldConfig": {"defaults": {"unit": unit, "decimals": decimals, "mappings": mappings or [],
                                         "thresholds": thresholds or TH_GREEN,
                                         "color": {"mode": "thresholds"}, "links": links or []},
                            "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "colorMode": "background", "graphMode": "none", "justifyMode": "center",
                        "textMode": text_mode, "orientation": "vertical", "wideLayout": True,
                        "showPercentChange": False}}


def row(pid, title, y):
    return {"id": pid, "type": "row", "title": title, "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


def team_link(label):
    return [{"title": "Open ${__field.labels." + label + "} status page", "targetBlank": False,
             "url": TEAM_DASH + "?var-owner=${__field.labels." + label + "}&${__url_time_range}"}]


LEGEND = """**Team status** (from `up` + mclabels, click a tile to open the team page)
🟢 Operational · 🟠 Degraded (replica / unassigned service down) · 🔴 Internal Outage (`internal` service down) · 🔴 Customer Outage (`customer` service down **or** a blackbox endpoint probe fails)

**Customer endpoints**: blackbox HTTP probes per team (public URLs and in-cluster liveness checks) (min = any URL failing → Down).

**Uptime by team**: per service, averaged over the time range, split by `mclabels.criticality`. *unassigned* = criticality not set yet."""

panels = [
    row(1, "Teams", 0),
    stat(2, "Team status", {"h": 6, "w": 18, "x": 0, "y": 1}, STATUS, "{{" + OWN + "}}",
         mappings=STATUS_MAP, links=team_link(OWN),
         thresholds={"mode": "absolute", "steps": [{"color": "dark-red", "value": None},
                                                   {"color": "red", "value": 0.25},
                                                   {"color": "orange", "value": 0.5},
                                                   {"color": "green", "value": 1}]},
         desc="One tile per mclabels owner — new teams appear automatically. Click to open the team page."),
    {"id": 3, "type": "text", "title": "Legend", "gridPos": {"h": 10, "w": 6, "x": 18, "y": 1},
     "options": {"mode": "markdown", "content": LEGEND}},
    stat(4, "Customer endpoints (blackbox probes)", {"h": 4, "w": 18, "x": 0, "y": 7}, PROBES, "{{team}}",
         mappings=UPDOWN_MAP, links=team_link("team"),
         desc="URLs probed by blackbox-exporter-<team>. Down = at least one URL of the team fails."),
    failing_probes_panel(12, {"h": 6, "w": 24, "x": 0, "y": 11}, "blackbox-exporter-.*"),
    {"id": 5, "type": "table", "title": "Uptime by team (%)", "datasource": DS,
     "gridPos": {"h": 9, "w": 24, "x": 0, "y": 17}, "interval": "1m", "maxDataPoints": 1440,
     "targets": [target(UPTIME, "", fmt="table")],
     "transformations": [{"id": "groupingToMatrix", "options": {
         "columnField": CRIT, "rowField": OWN, "valueField": "Value", "emptyValue": "null"}},
         {"id": "organize", "options": {"renameByName": {f"{OWN}\\{CRIT}": "Team"},
                                        "indexByName": {f"{OWN}\\{CRIT}": 0, "customer": 1,
                                                        "internal": 2, "unassigned": 3}}}],
     "fieldConfig": {"defaults": {"unit": "percent", "decimals": 2, "thresholds": TH_UPTIME,
                                  "noValue": "—", "mappings": [{"type": "special", "options": {"match": "null+nan", "result": {"text": "—", "color": "transparent", "index": 0}}}], "custom": {"cellOptions": {"type": "color-background", "mode": "basic"},
                                             "align": "center"}},
                     "overrides": [{"matcher": {"id": "byName", "options": "Team"},
                                    "properties": [{"id": "custom.cellOptions", "value": {"type": "auto"}},
                                                   {"id": "links", "value": [{
                                                       "title": "Open team page",
                                                       "url": TEAM_DASH + "?var-owner=${__value.raw}&${__url_time_range}"}]}]}]},
     "options": {"showHeader": True, "cellHeight": "sm"}},
    row(6, "Infrastructure", 26),
    stat(7, "Core infrastructure (TCP)", {"h": 5, "w": 10, "x": 0, "y": 27}, TCP, "{{instance}}",
         mappings=UPDOWN_MAP, desc="blackbox TCP probes: S3, PostgreSQL, SFTPGo."),
    stat(8, "TLS certificates — days left", {"h": 5, "w": 14, "x": 10, "y": 27}, CERTS, "{{host}}",
         unit="suffix: days", decimals=0,
         thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None},
                                                   {"color": "orange", "value": 14},
                                                   {"color": "green", "value": 30}]},
         desc="Earliest certificate expiry per probed host (probe_ssl_earliest_cert_expiry)."),
    row(9, "Alerts", 32),
    stat(10, "Firing alerts by severity", {"h": 8, "w": 6, "x": 0, "y": 33}, ALERTS_BY_SEV, "{{severity}}",
         thresholds={"mode": "absolute", "steps": [{"color": "blue", "value": None}]},
         desc="Currently firing Prometheus alerts by severity."),
    {"id": 11, "type": "table", "title": "Firing alerts", "datasource": DS,
     "gridPos": {"h": 8, "w": 18, "x": 6, "y": 33},
     "targets": [target(ALERTS_TABLE, "", fmt="table")],
     "transformations": [{"id": "organize", "options": {
         "excludeByName": {"Time": True},
         "renameByName": {"alertname": "Alert", "severity": "Severity", "alert_team": "Team",
                          "namespace": "Namespace", "Value": "Firing since"},
         "indexByName": {"Severity": 0, "alertname": 1, "alert_team": 2, "namespace": 3, "Value": 4}}},
         {"id": "sortBy", "options": {"sort": [{"field": "Firing since", "desc": True}]}}],
     "fieldConfig": {"defaults": {"custom": {"align": "left", "filterable": True}},
                     "overrides": [
                         {"matcher": {"id": "byName", "options": "Firing since"},
                          "properties": [{"id": "unit", "value": "dateTimeFromNow"}]},
                         {"matcher": {"id": "byName", "options": "Severity"},
                          "properties": [{"id": "custom.cellOptions", "value": {"type": "color-text"}},
                                         {"id": "mappings", "value": [{"type": "value", "options": {
                                             "critical": {"color": "red", "index": 0},
                                             "warning": {"color": "orange", "index": 1},
                                             "info": {"color": "blue", "index": 2}}}]}]}]},
     "options": {"showHeader": True, "cellHeight": "sm"}},
]
panels[1]["options"]["text"] = {"titleSize": 16, "valueSize": 20}  # team status tiles
# colour the severity stat tiles
panels[-2]["fieldConfig"]["overrides"] = [
    {"matcher": {"id": "byName", "options": s},
     "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
    for s, c in (("critical", "red"), ("warning", "orange"), ("info", "blue"))]

dash = {
    "uid": "at9fgw", "title": "MapColonies Status (beta)",
    "description": "Central status page: teams (mclabels), infrastructure, alerts. MAPCO-5786.",
    "tags": ["status-page", "mclabels", "beta"], "timezone": "browser", "editable": True,
    "refresh": "1m", "time": {"from": "now-24h", "to": "now"}, "schemaVersion": 41, "graphTooltip": 1,
    "templating": {"list": [{"name": "Site", "label": "Site", "type": "datasource", "query": "prometheus",
                             "current": {"text": "Prometheus", "value": "prometheus"}, "refresh": 1,
                             "regex": ""}]},
    "panels": panels, "annotations": {"list": []},
    "links": [{"title": "Team status page", "type": "link", "url": TEAM_DASH, "icon": "dashboard"}],
}

if len(sys.argv) > 2:  # dump queries for testing
    json.dump({p["title"]: p["targets"][0]["expr"] for p in panels if p.get("targets")},
              open(sys.argv[2], "w"))
json.dump(dash, open(sys.argv[1], "w"), indent=2)
