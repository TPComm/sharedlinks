"""Stands in for Grafana Cloud in deploy/test/e2e.sh: accepts Loki and Prometheus pushes on
127.0.0.1 and writes one JSON line per push to the log file (the Loki streams' units decoded).

    python3 deploy/test/grafana-stub.py PORT LOG
"""
import http.server
import json
import sys

port, log = int(sys.argv[1]), open(sys.argv[2], "a", buffering=1)


class Push(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        entry = {"path": self.path, "auth": self.headers.get("Authorization", ""), "bytes": len(body)}
        if self.path.startswith("/loki/"):
            streams = json.loads(body)["streams"]
            entry["streams"] = [s["stream"] for s in streams]
            entry["lines"] = [v[1] for s in streams for v in s["values"]]
        log.write(json.dumps(entry) + "\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Push).serve_forever()
