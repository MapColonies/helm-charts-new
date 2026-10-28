"""Minimal Kubernetes API for the e2e tests.

Usage: fake-kube-api.py <port> <lines> <record>
- Serves the logs of every container: <lines> is a number of lines ("line N", one per second,
  ending now), or a file of "<age in seconds> <line>" rows; a negative age is a line written that
  many seconds after the start.
- Records every log request in <record> as "<namespace>/<pod> <sinceTime or none>".
- Lists one running pod, ns/pod (container app, owned by ReplicaSet app-5d9f8), for discovery, with
  a watch that never reports a change. Anything else is a 404.
"""
import json, os, sys, time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

port, lines, record = int(sys.argv[1]), sys.argv[2], sys.argv[3]
now = datetime.now(timezone.utc).replace(microsecond=0)
if os.path.isfile(lines):
    with open(lines) as f:
        rows = [row.rstrip("\n").split(" ", 1) for row in f if row.strip()]
    LOG = sorted((now - timedelta(seconds=int(age)), line) for age, line in rows)
else:
    LOG = [(now - timedelta(seconds=int(lines) - i), f"line {i}") for i in range(1, int(lines) + 1)]

POD = {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {
        "name": "pod",
        "namespace": "ns",
        "uid": "uid-1",
        "resourceVersion": "1",
        "labels": {"mapcolonies.io/alloy-api-logs": "true", "mapcolonies.io/owner": "team-a"},
        "ownerReferences": [
            {"apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "app-5d9f8", "uid": "rs-1", "controller": True}
        ],
    },
    "spec": {"nodeName": "node-1", "containers": [{"name": "app", "image": "app"}]},
    "status": {
        "phase": "Running",
        "podIP": "10.0.0.1",
        "hostIP": "10.0.1.1",
        "conditions": [{"type": "Ready", "status": "True"}],
        "containerStatuses": [
            {"name": "app", "ready": True, "restartCount": 0, "image": "app", "imageID": "",
             "state": {"running": {"startedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ")}}}
        ],
    },
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        parts = url.path.split("/")  # ['', 'api', 'v1', 'namespaces', <ns>, 'pods', <pod>, 'log']
        query = parse_qs(url.query)
        if url.path == "/version":
            return self.send_json({"major": "1", "minor": "30", "gitVersion": "v1.30.0"})
        if len(parts) == 6 and parts[5] == "pods":
            items = [POD] if parts[4] == POD["metadata"]["namespace"] else []
            if query.get("watch") == ["true"]:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                if query.get("sendInitialEvents") == ["true"]:
                    # watch-list: the current pods, then a bookmark that ends the initial events
                    for pod in items:
                        self.wfile.write(json.dumps({"type": "ADDED", "object": pod}).encode() + b"\n")
                    bookmark = {"kind": "Pod", "apiVersion": "v1", "metadata": {
                        "resourceVersion": "1", "annotations": {"k8s.io/initial-events-end": "true"}}}
                    self.wfile.write(json.dumps({"type": "BOOKMARK", "object": bookmark}).encode() + b"\n")
                    self.wfile.flush()
                time.sleep(3600)  # no changes to report
                return
            return self.send_json({"apiVersion": "v1", "kind": "PodList", "metadata": {"resourceVersion": "1"}, "items": items})
        if len(parts) == 7 and parts[5] == "pods" and (parts[4], parts[6]) == ("ns", "pod"):
            return self.send_json(POD)
        if len(parts) != 8 or parts[7] != "log":
            self.send_response(404)
            self.end_headers()
            return
        since = query.get("sinceTime", [""])[0]
        with open(record, "a") as f:
            f.write(f"{parts[4]}/{parts[6]} {since or 'none'}\n")
        start = datetime.fromisoformat(since.replace("Z", "+00:00")) if since else None
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        for ts, line in LOG:  # follow=true: past lines now, future ones (negative age) when they're due
            if start is None or ts >= start:
                time.sleep(max(0, (ts - datetime.now(timezone.utc)).total_seconds()))
                self.wfile.write(f"{ts.strftime('%Y-%m-%dT%H:%M:%S.%fZ')} {line}\n".encode())
                self.wfile.flush()
        time.sleep(3600)  # keep the stream open


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
