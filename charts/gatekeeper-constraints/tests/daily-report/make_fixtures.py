"""Writes tests/daily-report/fixtures (run through `make daily-report-fixtures`).

  python3 -I make_fixtures.py TEMPLATES_JSONL GATOR OUT_DIR

fixtures/api/*.json are raw API responses as `kubectl get --raw` returns them: list items
carry no kind or apiVersion. The ConstraintTemplates are the chart's own (TEMPLATES_JSONL,
from yaml2json.sh). fixtures/gator-results.json is what the real gator returns for
report.py's projection of fixtures/api, trimmed to the fields report.py reads.
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, "..", "..", "files", "daily-report", "report.py")
AUDIT_TS = "2026-10-26T07:00:00Z"
OWNER_OK = {"mapcolonies.io/owner": "raster", "mapcolonies.io/environment": "dev",
            "mapcolonies.io/part-of": "p", "mapcolonies.io/component": "c"}


def container(name, request, limit):
    res = {}
    if request:
        res.setdefault("requests", {})["cpu"] = request
    if limit:
        res.setdefault("limits", {})["cpu"] = limit
    return {"name": name, "image": "registry.invalid/%s:1" % name,
            "env": [{"name": "PASSWORD", "value": "must-not-leave-the-pod"}], "resources": res}


def workload(ns, name, labels, containers, init=None, annotations=None):
    meta = {"name": name, "namespace": ns, "uid": "u-%s-%s" % (ns, name), "resourceVersion": "1",
            "annotations": dict({"kubectl.kubernetes.io/last-applied-configuration": "{}"}, **(annotations or {}))}
    spec = {"containers": containers}
    if init:
        spec["initContainers"] = init
    return {"metadata": meta, "spec": {"replicas": 1, "selector": {"matchLabels": {"app": name}},
                                        "template": {"metadata": {"labels": dict({"app": name}, **labels)},
                                                     "spec": spec}},
            "status": {"replicas": 1}}


def api_list(kind, items, api_version):
    return {"kind": kind, "apiVersion": api_version, "metadata": {"resourceVersion": "1"}, "items": items}


def constraint(name, namespaces, action, total, exemptions=()):
    return {"metadata": {"name": name, "generation": 1},
            "spec": {"enforcementAction": action,
                     "match": {"scope": "Namespaced", "namespaces": namespaces,
                               "kinds": [{"apiGroups": ["apps"], "kinds": ["Deployment", "StatefulSet"]}]},
                     "parameters": {"exemptions": list(exemptions)}},
            "status": {"auditTimestamp": AUDIT_TS, "totalViolations": total}}


def main(templates_jsonl, gator, out):
    api = os.path.join(out, "api")
    os.makedirs(api, exist_ok=True)

    def write(path, obj):
        with open(os.path.join(api, path.strip("/").replace("/", "_") + ".json"), "w") as f:
            json.dump(obj, f, indent=1, sort_keys=True)
            f.write("\n")

    with open(templates_jsonl) as f:
        for line in f:
            t = json.loads(line)
            if t.get("kind") == "ConstraintTemplate":
                write("/apis/templates.gatekeeper.sh/v1/constrainttemplates/" + t["metadata"]["name"], t)

    deployments = [
        # raster-dev (team raster, exact entry)
        workload("raster-dev", "api", {}, [container("app", "100m", "100m"), container("sidecar", None, None)]),
        workload("raster-dev", "exempt-listed", OWNER_OK, [container("app", "100m", "100m")]),
        workload("raster-dev", "exempt-annotated", OWNER_OK, [container("app", "100m", "100m")],
                 annotations={"mapcolonies.io/exempt-cpu-ratio": "Guaranteed QoS on purpose"}),
        workload("raster-dev", "compliant", OWNER_OK, [container("app", "250m", "1")]),
        # vector-dev: init container, missing + invalid labels on one workload
        workload("vector-dev", "init-bad", {"mapcolonies.io/owner": "vector", "mapcolonies.io/environment": "undefined",
                                             "mapcolonies.io/part-of": ""},
                 [container("app", "250m", "1")], init=[container("migrate", "100m", "1")]),
        # dem-dev (team 3d): matched by the warn and the enforced cpu-ratio Constraint
        workload("dem-dev", "overlap", OWNER_OK, [container("app", "100m", "200m")]),
        # gateway-dev: silenced
        workload("gateway-dev", "gw", OWNER_OK, [container("app", "100m", "100m")]),
        # misc-dev: no entry -> defaultTeam; owner not an allowed domain
        workload("misc-dev", "m", dict(OWNER_OK, **{"mapcolonies.io/owner": "nobody"}), [container("app", "1", "4")]),
        # prod: out of every Constraint's scope
        workload("prod", "p", {}, [container("app", "100m", "100m")]),
    ]
    statefulsets = [
        workload("raster-dev", "db", dict(OWNER_OK, **{"mapcolonies.io/component": ""}), [container("pg", "500m", "2")]),
    ]
    write("/apis/apps/v1/deployments", api_list("DeploymentList", deployments, "apps/v1"))
    write("/apis/apps/v1/statefulsets", api_list("StatefulSetList", statefulsets, "apps/v1"))
    write("/api/v1/namespaces", api_list("NamespaceList", [
        {"metadata": {"name": n, "labels": {"kubernetes.io/metadata.name": n}}, "status": {"phase": "Active"}}
        for n in ("raster-dev", "vector-dev", "3d-dev", "dem-dev", "gateway-dev", "misc-dev", "prod")], "v1"))
    exemption = {"namespace": "raster-dev", "kind": "Deployment", "name": "exempt-listed",
                 "reason": "test"}
    # totalViolations = what the audit would count (checked by test_report.py against gator).
    write("/apis/constraints.gatekeeper.sh/v1beta1/k8sworkloadcpuratio", api_list("K8sWorkloadCpuRatioList", [
        constraint("workload-cpu-ratio-warn", ["*-dev"], "warn", 5, [exemption]),
        constraint("workload-cpu-ratio-enforced", ["dem-dev"], "deny", 1),
    ], "constraints.gatekeeper.sh/v1beta1"))
    write("/apis/constraints.gatekeeper.sh/v1beta1/k8sworkloadmclabels", api_list("K8sWorkloadMcLabelsList", [
        constraint("workload-mclabels-warn", ["*-dev"], "warn", 4),
    ], "constraints.gatekeeper.sh/v1beta1"))

    # gator on report.py's own projection of the fixtures.
    with tempfile.TemporaryDirectory() as work:
        teams = os.path.join(work, "teams.json")
        with open(teams, "w") as f:
            json.dump({"entries": [], "defaultTeam": "infra", "teams": ["infra"], "webhookEnv": {"infra": "INFRA_WEBHOOK"}}, f)
        subprocess.run([sys.executable, "-I", REPORT, "--from-files", api, "--dry-run", "--teams", teams,
                        "--gator", gator, "--work", work], check=False, stdout=subprocess.DEVNULL,
                       env={"PATH": os.environ.get("PATH", "")})
        p = subprocess.run([gator, "test", "-f", os.path.join(work, "in"), "-o", "json"],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, check=True)
    results = json.loads(p.stdout or b"null") or []
    trimmed = [{"constraint": {"kind": r["constraint"]["kind"], "metadata": {"name": r["constraint"]["metadata"]["name"]}},
                "enforcementAction": r["enforcementAction"], "msg": r["msg"],
                "violatingObject": {"kind": r["violatingObject"]["kind"],
                                    "metadata": {k: r["violatingObject"]["metadata"][k] for k in ("name", "namespace")}}}
               for r in results]
    trimmed.sort(key=lambda r: (r["constraint"]["metadata"]["name"], r["violatingObject"]["metadata"]["namespace"],
                                r["violatingObject"]["metadata"]["name"], r["msg"]))
    with open(os.path.join(out, "gator-results.json"), "w") as f:
        json.dump(trimmed, f, indent=1, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main(*sys.argv[1:])
