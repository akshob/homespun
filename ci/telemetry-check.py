#!/usr/bin/env python3
"""Summarises what the app sent to the stub and checks nothing personal went along."""
import collections, json, sys

LOG, FORBIDDEN = sys.argv[1], sys.argv[2:]
requests = [json.loads(line) for line in open(LOG)]

def kind(r):
    parts = r["path"].split("/")
    return f'{r["method"]} {parts[2] if len(parts) > 2 else r["path"]}'

print("requests:", dict(collections.Counter(kind(r) for r in requests)))
names = collections.Counter(e["name"] for r in requests if r["path"] == "/v1/events" for e in r["body"]["events"])
print("events:", dict(names))
problems = [f'wrong key on {r["path"]}' for r in requests if r["key"] != "homespun-app-v1"]
text = json.dumps(requests)
problems += [f"sent {word!r}" for word in FORBIDDEN if word in text]
for r in requests:
    if r["path"] == "/v1/reports":
        b = r["body"]
        print("report:", {"install": b.get("install"), "message": b.get("message"), "email": b.get("email"),
                          "diagnostics": sorted(b.get("diagnostics") or {})})
print("problems:", problems or "none")
sys.exit(1 if problems else 0)
