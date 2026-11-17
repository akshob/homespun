#!/usr/bin/env python3
"""Answers like the telemetry Worker and records each request (JSON lines) for the UI tests."""
import http.server, json, sys

PORT, LOG = int(sys.argv[1]), sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def record(self, body):
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "key": self.headers.get("X-Homespun-Key"), "body": body}) + "\n")

    def reply(self, status, obj=None):
        data = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(status)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            body = json.loads(raw)
        except ValueError:
            body = None
        self.record(body)
        if self.path == "/v1/reports":
            self.reply(201, {"id": "HS-TEST01"})
        elif self.path == "/v1/events":
            self.reply(202, {"accepted": len((body or {}).get("events", []))})
        else:
            self.reply(202, {})

    def do_DELETE(self):
        self.record(None)
        self.reply(204)

    def log_message(self, *args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
