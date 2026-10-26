"""Minimal Kubernetes API for the e2e tests: serves the logs of every container (LINES lines, one
per second, ending now) and records every log request as "<namespace>/<pod> <sinceTime or none>".
Anything else is a 404."""
import json, sys, time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

port, lines, record = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
now = datetime.now(timezone.utc).replace(microsecond=0)
LOG = [(now - timedelta(seconds=lines - i), f"line {i}") for i in range(1, lines + 1)]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/version":
            body = json.dumps({"major": "1", "minor": "30", "gitVersion": "v1.30.0"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return
        if not url.path.endswith("/log"):
            self.send_response(404)
            self.end_headers()
            return
        since = parse_qs(url.query).get("sinceTime", [""])[0]
        namespace, pod = url.path.split("/")[4], url.path.split("/")[6]  # /api/v1/namespaces/<ns>/pods/<pod>/log
        with open(record, "a") as f:
            f.write(f"{namespace}/{pod} {since or 'none'}\n")
        start = datetime.fromisoformat(since.replace("Z", "+00:00")) if since else None
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        for ts, line in LOG:
            if start is None or ts >= start:
                self.wfile.write(f"{ts.strftime('%Y-%m-%dT%H:%M:%S.%fZ')} {line}\n".encode())
        self.wfile.flush()
        time.sleep(3600)  # follow=true: keep the stream open


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
