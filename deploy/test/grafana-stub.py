"""Stands in for Grafana Cloud in deploy/test/e2e.sh: accepts Loki and Prometheus pushes on
127.0.0.1 and writes one JSON line per push to the log file (the Loki streams and the remote-write
series' labels decoded).

    python3 deploy/test/grafana-stub.py PORT LOG
"""
import http.server
import json
import sys

port, log = int(sys.argv[1]), open(sys.argv[2], "a", buffering=1)


def varint(buf, i):
    n = shift = 0
    while True:
        b = buf[i]
        i += 1
        n |= (b & 0x7F) << shift
        shift += 7
        if b < 0x80:
            return n, i


def unsnappy(buf):
    """Snappy's block format, which remote write uses; the runner has no snappy module."""
    size, i = varint(buf, 0)
    out = bytearray()
    while i < len(buf):
        tag = buf[i]
        i += 1
        kind = tag & 3
        if kind == 0:
            n = tag >> 2
            if n >= 60:
                extra = n - 59
                n = int.from_bytes(buf[i:i + extra], "little")
                i += extra
            out += buf[i:i + n + 1]
            i += n + 1
            continue
        if kind == 1:
            n, offset = ((tag >> 2) & 7) + 4, ((tag >> 5) << 8) | buf[i]
            i += 1
        else:
            width = 2 if kind == 2 else 4
            n, offset = (tag >> 2) + 1, int.from_bytes(buf[i:i + width], "little")
            i += width
        for _ in range(n):  # copies may overlap their own output
            out.append(out[-offset])
    assert len(out) == size
    return bytes(out)


def fields(buf):
    """(field number, bytes) for each length-delimited protobuf field; other kinds are skipped."""
    i = 0
    while i < len(buf):
        key, i = varint(buf, i)
        wire = key & 7
        if wire == 0:
            _, i = varint(buf, i)
        elif wire == 1:
            i += 8
        elif wire == 5:
            i += 4
        elif wire == 2:
            n, i = varint(buf, i)
            yield key >> 3, buf[i:i + n]
            i += n
        else:
            raise ValueError(f"wire type {wire}")


def series_labels(body):
    """The labels of each series in a WriteRequest (TimeSeries = 1, its Label = 1, name 1, value 2)."""
    return [
        {
            dict(fields(label)).get(1, b"").decode(): dict(fields(label)).get(2, b"").decode()
            for number, label in fields(ts)
            if number == 1
        }
        for number, ts in fields(unsnappy(body))
        if number == 1
    ]


class Push(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        entry = {"path": self.path, "auth": self.headers.get("Authorization", ""), "bytes": len(body)}
        if self.path.startswith("/loki/"):
            streams = json.loads(body)["streams"]
            entry["streams"] = [s["stream"] for s in streams]
            entry["lines"] = [v[1] for s in streams for v in s["values"]]
        elif self.path.startswith("/api/prom/"):
            entry["series"] = series_labels(body)
        log.write(json.dumps(entry) + "\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Push).serve_forever()
