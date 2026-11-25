"""Minimal OTLP/HTTP receiver for the e2e tests: accepts JSON-encoded exports (the exporter's
`encoding = "json"`) on any path and appends each request body, one per line, to <record>.

Usage: fake-otlp-receiver.py <port> <record>
"""
import gzip, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, record = int(sys.argv[1]), sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        if self.path.endswith("/v1/logs"):
            with open(record, "ab") as f:
                f.write(body.replace(b"\n", b"") + b"\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
