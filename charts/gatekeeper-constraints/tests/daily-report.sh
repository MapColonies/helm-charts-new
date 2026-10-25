#!/usr/bin/env bash
# Asserts on the rendered daily report (templates/daily-report*.yaml): off by default, where
# each object lands, webhook env from secretKeyRef only, read-only RBAC, 1:4 CPU, pinned
# gator, teams.json order, and the two Grafana rules.
set -euo pipefail
cd "$(dirname "$0")/.."

render() { helm template gatekeeper-constraints . -n gatekeeper-system "$@"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# json <rendered yaml> <python expression on `docs` (list of objects)>: prints the result
json() {
  printf '%s\n' "$1" > "$tmp/in.yaml"
  tests/daily-report/yaml2json.sh "$tmp/in.yaml" > "$tmp/in.jsonl"
  python3 -I -c '
import json, sys
docs = [json.loads(l) for l in open(sys.argv[1])]
def one(kind): return [d for d in docs if d["kind"] == kind and "daily-report" in d["metadata"]["name"]][0]
v = eval(sys.argv[2])
print(v if isinstance(v, str) else json.dumps(v, sort_keys=True))' "$tmp/in.jsonl" "$2"
}
on=(--set dailyReport.enabled=true --set dailyReport.namespace=infra-dev --set dailyReport.environment=dev
    --set dailyReport.dashboardUrl=https://grafana.invalid/d/gk-workload-policy
    --set dailyReport.loki.pushUrl=http://infra-loki-gateway.infra-dev/loki/api/v1/push)
# the dev mapping (site-values infra/gatekeeper-constraints/dev.yaml)
teams=(--set 'namespaceTeams[0].namespace=raster-dev' --set 'namespaceTeams[0].team=raster'
       --set 'namespaceTeams[1].namespace=vector-dev' --set 'namespaceTeams[1].team=vector'
       --set 'namespaceTeams[2].namespace=3d-dev'     --set 'namespaceTeams[2].team=3d'
       --set 'namespaceTeams[3].namespace=dem-dev'    --set 'namespaceTeams[3].team=3d'
       --set 'namespaceTeams[4].namespace=infra-dev'  --set 'namespaceTeams[4].team=infra'
       --set 'namespaceTeams[5].namespace=gateway-dev' --set 'namespaceTeams[5].silence=true'
       --set 'namespaceTeams[6].namespace=*-dev'      --set 'namespaceTeams[6].team=app'
       --set 'namespaceTeams[7].namespace=meridian-dev' --set 'namespaceTeams[7].silence=true')

# 1. off by default, also with namespaceTeams set
out=$(render "${teams[@]}")
grep -q 'daily-report' <<<"$out" && fail "default render must not contain the daily report"

# 2. on: every namespaced object in dailyReport.namespace, rules in the release namespace
out=$(render "${on[@]}" "${teams[@]}")
[ "$(json "$out" '[d["kind"] for d in docs if "daily-report" in d["metadata"]["name"]]')" = \
  '["ServiceAccount", "ConfigMap", "ConfigMap", "ClusterRole", "ClusterRoleBinding", "CronJob"]' ] \
  || fail "unexpected daily-report objects"
[ "$(json "$out" 'sorted({d["metadata"].get("namespace", "-") for d in docs if d["metadata"]["name"].endswith("daily-report")})')" = \
  '["-", "infra-dev"]' ] || fail "daily-report objects must be in dailyReport.namespace (or cluster-scoped)"
[ "$(json "$out" '[d["metadata"]["namespace"] for d in docs if d["metadata"]["name"].endswith("daily-report-alerts")]')" = \
  '["gatekeeper-system"]' ] || fail "the rule ConfigMap must be in the release namespace"
[ "$(json "$out" 'one("ClusterRoleBinding")["subjects"]')" = \
  '[{"kind": "ServiceAccount", "name": "gatekeeper-constraints-daily-report", "namespace": "infra-dev"}]' ] \
  || fail "ClusterRoleBinding must bind the job's ServiceAccount"

# 3. webhooks: exactly one optional secretKeyRef per team (digit rule), never a literal URL
cron='one("CronJob")["spec"]["jobTemplate"]["spec"]["template"]'
[ "$(json "$out" "[e['name'] for e in $cron['spec']['containers'][0]['env'] if 'valueFrom' in e]")" = \
  '["RASTER_WEBHOOK", "VECTOR_WEBHOOK", "TEAM_3D_WEBHOOK", "INFRA_WEBHOOK", "APP_WEBHOOK"]' ] \
  || fail "webhook env must be one per team plus defaultTeam"
[ "$(json "$out" "sorted({json.dumps(e['valueFrom']['secretKeyRef']['optional']) + e['valueFrom']['secretKeyRef']['name'] + str(e['valueFrom']['secretKeyRef']['key'] == e['name']) for e in $cron['spec']['containers'][0]['env'] if 'valueFrom' in e})")" = \
  '["truegrafana-webhooks-externalTrue"]' ] || fail "webhooks must be optional secretKeyRefs on webhooksSecret, key = env name"
[ "$(json "$out" "[e['name'] for e in $cron['spec']['containers'][0]['env'] if 'WEBHOOK' in e['name'] and 'value' in e]")" = '[]' ] \
  || fail "a webhook env var has a literal value"
grep -qi 'hooks.slack.com' <<<"$out" && fail "rendered output contains a Slack webhook URL"

# 4. RBAC: get/list only, no Secrets, no pods/log, constraints of the configured kinds only
[ "$(json "$out" 'sorted({v for r in one("ClusterRole")["rules"] for v in r["verbs"]})')" = '["get", "list"]' ] \
  || fail "ClusterRole verbs must be get and list only"
[ "$(json "$out" 'sorted({x for r in one("ClusterRole")["rules"] for x in r["resources"]})')" = \
  '["constrainttemplates", "deployments", "k8sworkloadcpuratio", "k8sworkloadmclabels", "namespaces", "statefulsets"]' ] \
  || fail "ClusterRole resources must be the workloads, namespaces and the report's Gatekeeper kinds"
# ConstraintTemplates: get on the report's kinds only (resourceNames), never every template
templates_rule() {
  json "$1" '[r for r in one("ClusterRole")["rules"] if r["apiGroups"] == ["templates.gatekeeper.sh"]]'
}
[ "$(templates_rule "$out")" = \
  '[{"apiGroups": ["templates.gatekeeper.sh"], "resourceNames": ["k8sworkloadcpuratio", "k8sworkloadmclabels"], "resources": ["constrainttemplates"], "verbs": ["get"]}]' ] \
  || fail "constrainttemplates must be get-only and limited to constraintKinds by resourceNames"

# 5. the job Pod: CPU limit = 4x request, hardened, read-only root, python -I
[ "$(json "$out" "[c['resources'] for c in $cron['spec']['containers']][0]['limits']['cpu']")" = 200m ] || fail "cpu limit"
[ "$(json "$out" "[c['resources'] for c in $cron['spec']['containers']][0]['requests']['cpu']")" = 50m ] || fail "cpu request"
cpu_ratio_ok() {
  json "$1" "all(int(c['resources']['limits']['cpu'].rstrip('m')) == 4 * int(c['resources']['requests']['cpu'].rstrip('m')) for c in $cron['spec']['containers'])"
}
[ "$(cpu_ratio_ok "$out")" = true ] || fail "job CPU limit must be 4x the request"
[ "$(json "$out" "$cron['spec']['containers'][0]['securityContext']")" = \
  '{"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}, "readOnlyRootFilesystem": true, "runAsNonRoot": true}' ] \
  || fail "container securityContext"
[ "$(json "$out" "$cron['spec']['securityContext']['seccompProfile']['type']")" = RuntimeDefault ] || fail "seccomp"
[ "$(json "$out" "$cron['spec']['containers'][0]['command'][:3]")" = '["python3", "-I", "-B"]' ] || fail "python3 -I"
[ "$(json "$out" 'one("CronJob")["spec"]["schedule"] + " " + one("CronJob")["spec"]["concurrencyPolicy"]')" = '30 7 * * 0-4 Forbid' ] \
  || fail "default schedule must be Sun-Thu 07:30 UTC, Forbid"
[ "$(json "$out" 'one("CronJob")["spec"]["jobTemplate"]["spec"]["backoffLimit"]')" = 0 ] || fail "backoffLimit must be 0"
# the wiring the job needs to run at all: script and teams.json inside the ConfigMap mount,
# --work on an emptyDir (the root filesystem is read-only), the bound ServiceAccount, no retry
python3 -I -c '
import json, sys
docs = [json.loads(l) for l in open(sys.argv[1])]
one = lambda kind: [d for d in docs if d["kind"] == kind and d["metadata"]["name"].endswith("daily-report")][0]
job = one("CronJob")["spec"]["jobTemplate"]["spec"]
pod = job["template"]["spec"]
c = pod["containers"][0]
volumes = {v["name"]: v for v in pod["volumes"]}
mounts = {m["mountPath"]: volumes[m["name"]] for m in c["volumeMounts"]}
def volume_of(path):
    return [v for m, v in mounts.items() if path.startswith(m.rstrip("/") + "/")][0]
cmd = c["command"]
cm = one("ConfigMap")["metadata"]["name"]
assert cmd[3].endswith("/report.py") and volume_of(cmd[3]).get("configMap", {}).get("name") == cm, cmd
assert volume_of(cmd[cmd.index("--teams") + 1]).get("configMap", {}).get("name") == cm, cmd
assert "emptyDir" in mounts[cmd[cmd.index("--work") + 1]], "--work must be an emptyDir mount"
env = {e["name"]: e.get("value") for e in c["env"]}
assert env["HOME"] == env["TMPDIR"] == cmd[cmd.index("--work") + 1], env
assert pod["serviceAccountName"] == one("ClusterRoleBinding")["subjects"][0]["name"] == one("ServiceAccount")["metadata"]["name"]
assert (pod["restartPolicy"], job["activeDeadlineSeconds"]) == ("Never", 900), (pod["restartPolicy"], job.get("activeDeadlineSeconds"))
' "$tmp/in.jsonl" || fail "CronJob wiring (mounts, --work, ServiceAccount, restartPolicy, activeDeadlineSeconds)"

# 6. the ConfigMap carries report.py byte for byte, and teams.json in matching order
[ "$(json "$out" "[d for d in docs if d['kind'] == 'ConfigMap' and 'report.py' in d['data']][0]['data']['report.py'] == open('files/daily-report/report.py').read()")" = true ] \
  || fail "ConfigMap report.py differs from files/daily-report/report.py"
teams_json=$(json "$out" "json.loads([d for d in docs if d['kind'] == 'ConfigMap' and 'teams.json' in d['data']][0]['data']['teams.json'])")
python3 -I -c '
import json, sys
t = json.loads(sys.argv[1])
assert [e["namespace"] for e in t["entries"]] == ["raster-dev", "vector-dev", "3d-dev", "dem-dev", "infra-dev", "gateway-dev", "meridian-dev", "*-dev"], "exact names first, then globs"
assert [e["team"] for e in t["entries"]][5:7] == [None, None], "silenced -> null"
assert t["entries"][7]["regex"] == ".*-dev", "glob as a regex"
assert t["defaultTeam"] == "infra" and t["teams"] == ["raster", "vector", "3d", "infra", "app"], t["teams"]
assert t["webhookEnv"]["3d"] == "TEAM_3D_WEBHOOK" and t["webhookEnv"]["infra"] == "INFRA_WEBHOOK"
' "$teams_json" || fail "teams.json"

# 7. every value reaches the job (rendered with non-defaults); dryRun is a string "true".
# report.py falls back to a default for a missing env var, so a dropped one would be silent.
out3=$(render "${on[@]}" --set dailyReport.dryRun=true --set dailyReport.postWhenClean=true \
  --set dailyReport.maxNamesPerRule=7 --set dailyReport.maxMessageChars=2000 \
  --set dailyReport.dashboardUrl=https://grafana.invalid/d/custom --set dailyReport.readmeUrl=https://readme.invalid/x \
  --set dailyReport.schedule='15 6 * * 1-5' --set 'dailyReport.constraintKinds={K8sWorkloadCpuRatio}' \
  --set dailyReport.loki.job=other-job --set dailyReport.webhooksSecret=other-secret)
[ "$(json "$out3" "{e['name']: e['value'] for e in $cron['spec']['containers'][0]['env'] if 'value' in e and e['name'] not in ('HOME', 'TMPDIR') and not e['name'].startswith('GATOR_')}")" = \
  '{"CONSTRAINT_KINDS": "K8sWorkloadCpuRatio", "DASHBOARD_URL": "https://grafana.invalid/d/custom", "DRY_RUN": "true", "LOKI_JOB": "other-job", "LOKI_URL": "http://infra-loki-gateway.infra-dev/loki/api/v1/push", "MAX_CHARS": "2000", "MAX_NAMES": "7", "POST_WHEN_CLEAN": "true", "README_URL": "https://readme.invalid/x", "SCHEDULE": "15 6 * * 1-5"}' ] \
  || fail "dailyReport values must reach the job env"
[ "$(json "$out3" 'one("CronJob")["spec"]["schedule"]')" = '15 6 * * 1-5' ] || fail "schedule must reach the CronJob"
[ "$(json "$out3" "sorted({e['valueFrom']['secretKeyRef']['name'] for e in $cron['spec']['containers'][0]['env'] if 'valueFrom' in e})")" = \
  '["other-secret"]' ] || fail "webhooksSecret must name every webhook secretKeyRef"
[ "$(json "$out3" 'sorted({x for r in one("ClusterRole")["rules"] for x in r["resources"] + r.get("resourceNames", []) if x.startswith("k8s")})')" = \
  '["k8sworkloadcpuratio"]' ] || fail "ClusterRole must follow constraintKinds"
[ "$(templates_rule "$out3")" = \
  '[{"apiGroups": ["templates.gatekeeper.sh"], "resourceNames": ["k8sworkloadcpuratio"], "resources": ["constrainttemplates"], "verbs": ["get"]}]' ] \
  || fail "constrainttemplates resourceNames must follow constraintKinds"
# and every env var report.py reads is rendered
python3 -I -c '
import json, re, sys
docs = [json.loads(l) for l in open(sys.argv[1])]
cron = [d for d in docs if d["kind"] == "CronJob"][0]
rendered = {e["name"] for e in cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["env"]}
src = open("files/daily-report/report.py").read()
config = src[src.index("def env_config"):src.index("class Runner")]
read = set(re.findall(r"(?:env\.get|flag)\(\"([A-Z_]+)\"", config))
assert len(read) > 10 and read <= rendered, sorted(read - rendered)
' "$tmp/in.jsonl" || fail "an env var report.py reads is not rendered"

# 8. gator: one version everywhere (values, Makefile, wrapped Gatekeeper), pinned sha256
version=$(json "$out" "[e['value'] for e in $cron['spec']['containers'][0]['env'] if e['name'] == 'GATOR_VERSION'][0]")
url=$(json "$out" "[e['value'] for e in $cron['spec']['containers'][0]['env'] if e['name'] == 'GATOR_URL'][0]")
make_version=$(sed -n 's/^GATOR_VERSION ?= //p' Makefile)
chart_version=v$(awk '/- name: gatekeeper/{getline; print $2}' Chart.yaml)
[ "$version" = "$make_version" ] || fail "dailyReport.gator.version $version != Makefile GATOR_VERSION $make_version"
[ "$version" = "$chart_version" ] || fail "dailyReport.gator.version $version != wrapped Gatekeeper $chart_version"
[ "$url" = "https://github.com/open-policy-agent/gatekeeper/releases/download/$version/gator-$version-linux-amd64.tar.gz" ] \
  || fail "gator url must be the $version linux-amd64 release tarball"
[ "$(json "$out" "[e['value'] for e in $cron['spec']['containers'][0]['env'] if e['name'] == 'GATOR_SHA256'][0]")" = \
  45ba8c54a22261473bddf6f4f18b154058d45b0c64f3e7a67b2fa781f0791800 ] || fail "gator sha256 pin changed"

# 9. Grafana rules: the dead-man (Loki runs AND Prometheus time gate) and the failed-run rule
rules=$(json "$out" "[d for d in docs if d['metadata']['name'].endswith('daily-report-alerts')][0]['data']['gatekeeper-daily-report.yaml']")
grep -q 'mapcolonies.io/grafana-alerts: "true"' <<<"$out" || fail "rule ConfigMap needs the alerts sidecar label"
printf '%s\n' "$rules" > "$tmp/rules.yaml"
tests/daily-report/yaml2json.sh "$tmp/rules.yaml" | python3 -I -c '
import json, sys
group = json.loads(sys.stdin.read())["groups"][0]
assert (group["name"], group["folder"]) == ("gatekeeper_daily_report", "Gatekeeper"), group["name"]
rules = {r["uid"]: r for r in group["rules"]}
assert sorted(rules) == ["gk-daily-report-failed", "gk-daily-report-missing"], sorted(rules)
for r in rules.values():
    assert r["labels"] == {"severity": "warning", "alert_team": "infra", "notify_resolved": "false"}, r["labels"]
    q = {d["refId"]: d for d in r["data"]}
    assert q[r["condition"]]["datasourceUid"] == "__expr__"
m = {d["refId"]: d for d in rules["gk-daily-report-missing"]["data"]}
assert m["A"]["model"]["expr"] == "sum(count_over_time({job=\"gatekeeper-workload-report\", team=\"_run\"} [9h])) or vector(0)", m["A"]["model"]["expr"]
assert m["B"]["datasourceUid"] == "prometheus"
assert m["B"]["model"]["expr"] == "(hour() >= bool 9) * (hour() < bool 16) * ((day_of_week() == bool 0) + (day_of_week() == bool 1) + (day_of_week() == bool 2) + (day_of_week() == bool 3) + (day_of_week() == bool 4))", m["B"]["model"]["expr"]
assert (m["C"]["model"]["type"], m["C"]["model"]["expression"]) == ("math", "$A < 1 && $B > 0")
assert rules["gk-daily-report-missing"]["execErrState"] == "KeepLast" and rules["gk-daily-report-missing"]["noDataState"] == "Alerting"
assert rules["gk-daily-report-missing"]["for"] == "15m"
f = {d["refId"]: d for d in rules["gk-daily-report-failed"]["data"]}
assert f["A"]["model"]["expr"] == "sum(count_over_time({job=\"gatekeeper-workload-report\", team=\"_run\"} | json | type=\"run\" | status!=\"ok\" [3h]))", f["A"]["model"]["expr"]
assert (f["C"]["model"]["type"], f["C"]["model"]["expression"]) == ("threshold", "A")
assert f["C"]["model"]["conditions"][0]["evaluator"] == {"params": [0], "type": "gt"}, f["C"]["model"]["conditions"]
failed = rules["gk-daily-report-failed"]
assert (failed["noDataState"], failed["execErrState"], failed["for"]) == ("OK", "OK", "0s"), failed
' || fail "daily-report rules"
grep -q '\${' <<<"$rules" && fail "rules must not contain \${...} (Grafana provisioning expands it as an env var)"
out2=$(render "${on[@]}" --set deployAlerts.defaultTeam=devops --set 'dailyReport.alerts.checkDays={1,3}' \
  --set dailyReport.alerts.checkFromHour=10 --set dailyReport.alerts.lookback=5h --set dailyReport.loki.job=other)
grep -q 'alert_team: devops' <<<"$out2" || fail "rules must go to deployAlerts.defaultTeam"
grep -qF '(hour() >= bool 10) * (hour() < bool 16) * ((day_of_week() == bool 1) + (day_of_week() == bool 3))' <<<"$out2" \
  || fail "check window must follow dailyReport.alerts"
grep -qF '{job=\"other\", team=\"_run\"} [5h]' <<<"$out2" || fail "lookback and job must follow dailyReport"
render "${on[@]}" --set dailyReport.alerts.enabled=false | grep -q 'daily-report-alerts' && fail "alerts.enabled=false must drop the rules"

# 10. defaultTeam gets a webhook even when no namespaceTeams entry names it (skipped and
# partial reports go only to defaultTeam)
default_team_webhook() {  # <expected team> <render args...>
  local team=$1 env o
  shift
  env=$(tr '[:lower:]' '[:upper:]' <<<"$team")_WEBHOOK
  o=$(render "${on[@]}" "$@")
  [ "$(json "$o" "[e['name'] for e in $cron['spec']['containers'][0]['env'] if e['name'] == '$env' and 'valueFrom' in e]")" = "[\"$env\"]" ] \
    || fail "defaultTeam $team needs $env"
  [ "$(json "$o" "(lambda t: t['defaultTeam'] == '$team' and '$team' in t['teams'])(json.loads([d for d in docs if d['kind'] == 'ConfigMap' and 'teams.json' in d['data']][0]['data']['teams.json']))")" = true ] \
    || fail "teams.json must name defaultTeam $team in teams"
}
default_team_webhook infra                                          # no namespaceTeams at all
default_team_webhook devops "${teams[@]}" --set deployAlerts.defaultTeam=devops   # not in namespaceTeams

# 11. gator.url may point at a mirror that has the version only in the file name
render "${on[@]}" --set dailyReport.gator.url=https://mirror.invalid/gatekeeper/gator-v3.22.0-linux-amd64.tar.gz > /dev/null \
  || fail "a mirror URL with the version in the file name must render"

echo "OK"
