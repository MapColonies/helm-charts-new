"""'Failing probes' table panel, shared by the overview and team dashboards.

Lists every blackbox probe that is failing *now*, with the details needed to triage it.
"""

DS = {"type": "prometheus", "uid": "${Site}"}


def failing_probes_panel(pid, grid_pos, job_regex):
    j = f'job=~"{job_regex}", job!="blackbox-exporter-tcp"'
    fail = f"(probe_success{{{j}}} == 0)"

    def norm(expr):
        return (f'max by (team, instance, job) (label_replace({expr}, "team", "$1", "job", '
                f'"blackbox-exporter-([a-z0-9]+).*"))')

    def only_failing(expr):
        return norm(f"({expr}) and on (instance, job) {fail}")

    queries = {
        "A": norm(fail),
        "B": only_failing(f"probe_http_status_code{{{j}}}"),
        "C": only_failing(f"probe_duration_seconds{{{j}}}"),
        "D": only_failing(f"(1 - avg_over_time(probe_success{{{j}}}[$__range])) * 100"),
        "E": only_failing(f"max_over_time(timestamp(probe_success{{{j}}} == 1)[$__range:$__interval]) * 1000"),
        "F": only_failing(f"probe_failed_due_to_regex{{{j}}}"),
    }
    targets = [{"datasource": DS, "editorMode": "code", "expr": q, "refId": r, "instant": True,
                "range": False, "format": "table", "legendFormat": ""} for r, q in queries.items()]

    def override(name, props):
        return {"matcher": {"id": "byName", "options": name}, "properties": props}

    status_text = {"0": "No response (timeout / refused)", "401": "401 Unauthorized",
                   "403": "403 Forbidden", "404": "404 Not Found", "500": "500 Server Error",
                   "502": "502 Bad Gateway", "503": "503 Unavailable", "504": "504 Gateway Timeout"}

    return {
        "id": pid, "type": "table", "title": "Failing probes", "datasource": DS, "gridPos": grid_pos,
        "interval": "1m", "maxDataPoints": 1440,
        "description": "Blackbox probes failing right now. Empty = all probes pass.",
        "targets": targets,
        "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {
                "excludeByName": {"Time": True, "Value #A": True},
                "indexByName": {"team": 0, "instance": 1, "Value #B": 2, "Value #E": 3, "Value #D": 4,
                                "Value #C": 5, "Value #F": 6, "job": 7},
                "renameByName": {"team": "Team", "instance": "URL", "job": "Probe job",
                                 "Value #B": "HTTP status", "Value #C": "Probe duration",
                                 "Value #D": "Failed % (time range)", "Value #E": "Last success",
                                 "Value #F": "Body check failed"}}},
        ],
        "fieldConfig": {
            "defaults": {"noValue": "✅ No failing probes", "custom": {"align": "left", "filterable": True}},
            "overrides": [
                override("HTTP status", [
                    {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                    {"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}},
                    {"id": "mappings", "value": [{"type": "value", "options": {
                        k: {"text": v, "index": i} for i, (k, v) in enumerate(status_text.items())}}]}]),
                override("Probe duration", [{"id": "unit", "value": "s"}, {"id": "decimals", "value": 2}]),
                override("Failed % (time range)", [
                    {"id": "unit", "value": "percent"}, {"id": "decimals", "value": 1},
                    {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                    {"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]),
                override("Last success", [{"id": "unit", "value": "dateTimeFromNow"},
                                          {"id": "noValue", "value": "not in time range"}]),
                override("Body check failed", [{"id": "mappings", "value": [{"type": "value", "options": {
                    "0": {"text": "no", "index": 0}, "1": {"text": "yes", "color": "red", "index": 1}}}]}]),
                override("URL", [{"id": "custom.width", "value": 330}]),
                override("Team", [{"id": "custom.width", "value": 80}]),
                override("HTTP status", [{"id": "custom.width", "value": 200}]),
            ]},
        "options": {"showHeader": True, "cellHeight": "sm",
                    "sortBy": [{"displayName": "Team", "desc": False}]},
    }
