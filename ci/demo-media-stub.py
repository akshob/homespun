#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Loopback-only reviewer-media fixture. Uses the existing synthetic CI JPEG, never R2."""
import hashlib
import json
import pathlib
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CODE = "TESTTESTTESTTEST"
TOKEN = "local-test-session"
JPEG = (pathlib.Path(__file__).parent / "seed/IMG_2002.JPG").read_bytes()


def dimensions(data):
    offset = 2
    while offset < len(data):
        assert data[offset] == 0xFF
        marker = data[offset + 1]
        size = struct.unpack_from(">H", data, offset + 2)[0]
        if marker in (0xC0, 0xC1, 0xC2):
            height, width = struct.unpack_from(">HH", data, offset + 5)
            return width, height
        offset += size + 2
    raise ValueError("No JPEG dimensions")


WIDTH, HEIGHT = dimensions(JPEG)
MANIFEST = {
    "version": 1,
    "totalBytes": len(JPEG) * 16,
    "files": [
        {"file": f"demo-test-{i}.jpg", "sha256": hashlib.sha256(JPEG).hexdigest(),
         "size": len(JPEG), "kind": "photo", "width": WIDTH, "height": HEIGHT,
         "date": "2025-01-01T10:00:00Z", "category": "nature"}
        for i in range(16)
    ],
}
COUNTS = {"sessions": 0, "files": 0}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log credentials, headers, or URLs.

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/v1/demo/session":
            return self.reply(403, {"error": "forbidden"})
        with LOCK:
            COUNTS["sessions"] += 1
        size = int(self.headers.get("Content-Length", "0"))
        if not 0 < size <= 256:
            return self.reply(403, {"error": "forbidden"})
        try:
            code = json.loads(self.rfile.read(size)).get("code", "")
        except (ValueError, AttributeError):
            code = ""
        if code != CODE:
            return self.reply(403, {"error": "forbidden"})
        time.sleep(2)  # Make the downloading phase observable without a test-only app delay.
        self.reply(200, {"manifest": MANIFEST, "token": TOKEN, "expiresAt": int(time.time()) + 600})

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"ok": True})
        if self.path == "/stats":
            with LOCK:
                counts = dict(COUNTS)
            return self.reply(200, counts)
        allowed = {"/v1/demo/files/" + f["file"] for f in MANIFEST["files"]}
        if self.path not in allowed or self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.reply(403, {"error": "forbidden"})
        with LOCK:
            COUNTS["files"] += 1
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(JPEG)))
        self.end_headers()
        try:
            for start in range(0, len(JPEG), 65536):
                self.wfile.write(JPEG[start:start + 65536])
                self.wfile.flush()
                time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
