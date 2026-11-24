"""Helpers for parity.sh and job-pod.sh. Input: one JSON object per line (yaml2json.sh).

  python3 -I helpers.py api DIR < objects.jsonl   raw API JSON files for report.py --from-files
  python3 -I helpers.py results < gator.json       gator results as sorted, comparable lines
  python3 -I helpers.py job-pod DIR < chart.jsonl  the daily-report CronJob's Pod (and the same
                                                   template as a Deployment) as gator objects
"""

import json
import os
import sys

LISTS = {"Deployment": "/apis/apps/v1/deployments", "StatefulSet": "/apis/apps/v1/statefulsets",
         "Namespace": "/api/v1/namespaces"}


def write(directory, path, obj):
    with open(os.path.join(directory, path.strip("/").replace("/", "_") + ".json"), "w") as f:
        json.dump(obj, f)


def api(directory):
    """List items lose kind and apiVersion, as in a real list response."""
    os.makedirs(directory, exist_ok=True)
    lists = {path: [] for path in LISTS.values()}
    namespaces = set()
    for line in sys.stdin:
        obj = json.loads(line)
        kind = obj["kind"]
        if kind == "ConstraintTemplate":
            write(directory, "/apis/templates.gatekeeper.sh/v1/constrainttemplates/" + obj["metadata"]["name"], obj)
            continue
        if obj["apiVersion"].startswith("constraints.gatekeeper.sh/"):
            path = "/apis/constraints.gatekeeper.sh/v1beta1/" + kind.lower()
        elif kind in LISTS:
            path = LISTS[kind]
            namespaces.add(obj["metadata"].get("namespace"))
        else:
            sys.exit("unexpected kind " + kind)
        item = {k: v for k, v in obj.items() if k not in ("kind", "apiVersion")}
        lists.setdefault(path, []).append(item)
    lists["/api/v1/namespaces"] += [{"metadata": {"name": n}} for n in sorted(namespaces - {None})]
    for path, items in lists.items():
        write(directory, path, {"kind": "List", "apiVersion": "v1", "metadata": {}, "items": items})


def results():
    """enforcementAction is left out: report.py runs every Constraint as warn on purpose."""
    for r in json.load(sys.stdin) or []:
        o = r["violatingObject"]
        print(json.dumps([r["constraint"]["kind"], r["constraint"]["metadata"]["name"], o["kind"],
                          o["metadata"].get("namespace"), o["metadata"]["name"], r["msg"]]))


def job_pod(directory):
    os.makedirs(directory, exist_ok=True)
    for line in sys.stdin:
        obj = json.loads(line)
        if obj.get("kind") == "CronJob":
            template = obj["spec"]["jobTemplate"]["spec"]["template"]
            ns = obj["metadata"]["namespace"]
            meta = dict(template["metadata"], name="daily-report-pod", namespace=ns)
            write(directory, "pod", {"apiVersion": "v1", "kind": "Pod", "metadata": meta, "spec": template["spec"]})
            write(directory, "deployment", {
                "apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "daily-report", "namespace": ns},
                "spec": {"selector": {"matchLabels": template["metadata"]["labels"]}, "template": template}})
            return
    sys.exit("no CronJob in the input")


if __name__ == "__main__":
    {"api": api, "results": results, "job-pod": job_pod}[sys.argv[1]](*sys.argv[2:])
