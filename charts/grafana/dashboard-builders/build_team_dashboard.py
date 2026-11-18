import json, sys
from failing_probes import failing_probes_panel

DS = {"type": "prometheus", "uid": "${Site}"}
S = 'mapcolonies_io_owner="$owner", namespace=~"$Namespace"'
SVC = "app_kubernetes_io_name"
CRIT = "mapcolonies_io_criticality"
PART = "mapcolonies_io_part_of"
COMP = "mapcolonies_io_component"


def fill(inner):
    """Fill missing service name / criticality labels."""
    return (f'label_replace(label_replace({inner}, "{SVC}", "unnamed", "{SVC}", ""), '
            f'"{CRIT}", "unassigned", "{CRIT}", "")')


def sel(extra=""):
    return "up{" + S + (", " + extra if extra else "") + "}"


def base(extra=""):
    return fill(sel(extra))


def svc_up(extra=""):
    """Per-service up (1 if any replica is up). A service that disappeared within the
    last 10m (pod deleted / not ready / crashloop) counts as 0 instead of vanishing.
    The fallback only applies while Prometheus itself has data (count(up) > 0), so a
    monitoring/cluster outage is a gap, not downtime."""
    by = f"{CRIT}, {PART}, {COMP}, {SVC}"
    return (f"(max by ({by}) ({base(extra)}) or on ({by}) "
            f"((0 * group by ({by}) ({fill('last_over_time(' + sel(extra) + '[10m])')}))"
            f" and on () (count(up) > 0)))")


def uptime(by, extra=""):
    return f"avg by ({by}) (avg_over_time({svc_up(extra)}[$__range:$__interval])) * 100"


# Public endpoint probes of the team (blackbox-exporter-<owner>[-with-headers]).
PROBE = 'probe_success{job=~"blackbox-exporter-$owner(-.*)?"}'


def crit_min(crit):
    # customer = customer-labelled services AND the team's blackbox endpoint probes
    extra = f" or {PROBE}" if crit == "customer" else ""
    return (f'(min(max by ({SVC}) (up{{{S}, {CRIT}="{crit}"}}){extra}) or vector(1))')


STATUS = (
    f"(vector(scalar{crit_min('customer')} * (0.25 + 0.25 * scalar{crit_min('internal')}"
    f" * (1 + 2 * scalar(min(up{{{S}}}) or vector(1)))))"
    f" and on () (count(up{{{S}}}) > 0))"
)

STATUS_MAPPINGS = [{"type": "value", "options": {
    "1": {"text": "Operational", "color": "green", "index": 0},
    "0.5": {"text": "Degraded", "color": "orange", "index": 1},
    "0.25": {"text": "Internal Outage", "color": "red", "index": 2},
    "0": {"text": "Customer Outage", "color": "dark-red", "index": 3}}}]

UPTIME_THRESHOLDS = {"mode": "absolute", "steps": [
    {"color": "red", "value": None}, {"color": "orange", "value": 95},
    {"color": "green", "value": 99.5}]}

LEGEND = """#### Status
- 🟢 **Operational** – all services and replicas up
- 🟠 **Degraded** – a replica, or a service without criticality, is down
- 🔴 **Internal Outage** – an `internal` service is down
- 🔴 **Customer Outage** – a `customer` service is down, or a blackbox endpoint probe fails

#### Criticality (`mclabels.criticality`)
- `customer` – external users notice within minutes if it is down
- `internal` – blocks our teams/pipelines, customers not directly affected

#### Uptime %
Per service (any replica up = up), averaged over the selected time range, split by `criticality`.
**unassigned** = services whose chart does not set `mclabels.criticality` yet.
Only services with `prometheus.enabled: true` appear."""


def target(expr, legend="", ref="A", instant=True):
    return {"datasource": DS, "editorMode": "code", "expr": expr, "legendFormat": legend,
            "refId": ref, "instant": instant, "range": not instant}


def stat(pid, title, pos, targets, unit="", mappings=None, thresholds=None, desc=""):
    return {
        "id": pid, "type": "stat", "title": title, "description": desc, "datasource": DS,
        "gridPos": pos, "targets": targets,
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": 2 if unit == "percent" else None,
            "mappings": mappings or [],
            "thresholds": thresholds or {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
            "color": {"mode": "thresholds"}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "background", "graphMode": "none", "justifyMode": "center",
                    "textMode": "value_and_name" if not mappings else "value",
                    "orientation": "auto", "wideLayout": True, "showPercentChange": False},
    }


panels = [
    {"id": 1, "type": "row", "title": "Overview", "collapsed": False,
     "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "panels": []},
    stat(2, "$owner Status", {"h": 7, "w": 7, "x": 0, "y": 1}, [target(STATUS)],
         mappings=STATUS_MAPPINGS,
         thresholds={"mode": "absolute", "steps": [{"color": "dark-red", "value": None},
                                                    {"color": "red", "value": 0.25},
                                                    {"color": "orange", "value": 0.5},
                                                    {"color": "green", "value": 1}]},
         desc="Current state. Customer > Internal > Degraded > Operational."),
    stat(3, "$owner Uptime", {"h": 7, "w": 10, "x": 7, "y": 1},
         [target(uptime(CRIT), "{{" + CRIT + "}}")], unit="percent",
         thresholds=UPTIME_THRESHOLDS,
         desc="Customer-facing and internal uptime % over the dashboard time range."),
    {"id": 4, "type": "text", "title": "Status Legend", "gridPos": {"h": 7, "w": 7, "x": 17, "y": 1},
     "options": {"mode": "markdown", "content": LEGEND}},
    stat(8, "Customer endpoints (blackbox probes)", {"h": 5, "w": 24, "x": 0, "y": 8},
         [target('label_replace(' + PROBE + ', "url", "$1", "instance", "https?://([^?]+).*")', "{{url}}")],
         mappings=[{"type": "value", "options": {"1": {"text": "Up", "color": "green", "index": 0},
                                                 "0": {"text": "Down", "color": "red", "index": 1}}}],
         desc="URLs probed by blackbox-exporter-$owner. Any Down = Customer Outage."),
    failing_probes_panel(9, {"h": 6, "w": 24, "x": 0, "y": 13}, "blackbox-exporter-$owner(-.*)?"),
    {"id": 5, "type": "row", "title": "$part_of", "repeat": "part_of", "collapsed": False,
     "gridPos": {"h": 1, "w": 24, "x": 0, "y": 19}, "panels": []},
    stat(6, "Uptime by component", {"h": 8, "w": 8, "x": 0, "y": 20},
         [target(uptime(f"{COMP}, {CRIT}", f'{PART}="$part_of"'),
                 "{{" + COMP + "}} ({{" + CRIT + "}})")],
         unit="percent", thresholds=UPTIME_THRESHOLDS),
    {
        "id": 7, "type": "status-history", "title": "Services", "datasource": DS,
        "gridPos": {"h": 8, "w": 16, "x": 8, "y": 20}, "interval": "1m", "maxDataPoints": 120,
        "targets": [target("avg by (" + SVC + ") (" + fill("avg_over_time(" + sel(PART + '="$part_of"')
                           + "[$__interval])") + ")", "{{" + SVC + "}}", instant=False)],
        "fieldConfig": {"defaults": {
            "unit": "percentunit", "min": 0, "max": 1, "color": {"mode": "thresholds"},
            "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": None},
                                                          {"color": "orange", "value": 0.01},
                                                          {"color": "green", "value": 1}]},
            "custom": {"fillOpacity": 80, "lineWidth": 0}}, "overrides": []},
        "options": {"showValue": "never", "rowHeight": 0.9, "legend": {"showLegend": False},
                    "tooltip": {"mode": "multi", "sort": "none"}},
        "description": "Share of replicas up per service. Orange = some replicas down.",
    },
]


# endpoint tiles: show the URL with the Up/Down value
for _p in panels:
    if _p["id"] == 8:
        _p["options"]["textMode"] = "value_and_name"
        _p["options"]["text"] = {"titleSize": 11, "valueSize": 26}
    # uptime subquery step = $__interval (>= 1m, ~range/1440): 1m at 24h, ~30m at 30d
    if _p["id"] in (3, 6):
        _p["interval"], _p["maxDataPoints"] = "1m", 1440


def qvar(name, query, multi, include_all, current, label=None):
    v = {"name": name, "label": label or name, "type": "query", "datasource": DS,
         "query": {"query": query, "refId": f"{name}-q", "qryType": 1},
         "definition": query, "refresh": 2, "sort": 1, "multi": multi,
         "includeAll": include_all, "current": current, "options": []}
    if include_all:
        v["allValue"] = ".*"
    return v


ALL = {"text": ["All"], "value": ["$__all"]}
templating = {"list": [
    {"name": "Site", "label": "Site", "type": "datasource", "query": "prometheus",
     "current": {"text": "Prometheus", "value": "prometheus"}, "refresh": 1, "regex": ""},
    qvar("owner", f"label_values(up, mapcolonies_io_owner)", False, False,
         {"text": "infra", "value": "infra"}, "Team"),
    qvar("Namespace", 'label_values(up{mapcolonies_io_owner="$owner"}, namespace)', True, True, ALL),
    qvar("part_of", f'label_values(up{{{S}}}, {PART})', True, True, ALL, "Part of"),
]}

dash = {
    "uid": "a6j7gg", "title": "Team Status Page (beta)",
    "description": "Dynamic team status page driven by mclabels (owner / partOf / component / criticality). "
                   "Pick a team with ?var-owner=<team>. MAPCO-5786.",
    "tags": ["status-page", "mclabels", "beta"], "timezone": "browser", "editable": True,
    "refresh": "1m", "time": {"from": "now-24h", "to": "now"}, "schemaVersion": 41,
    "graphTooltip": 1, "templating": templating, "panels": panels, "annotations": {"list": []},
    "links": [],
}

json.dump(dash, open(sys.argv[1], "w"), indent=2)
