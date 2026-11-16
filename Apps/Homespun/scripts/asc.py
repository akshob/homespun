#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A little App Store Connect API for Homespun's TestFlight builds (no extra packages; signs with openssl).

  asc.py builds            the latest builds and their processing state
  asc.py testers           creates the internal group "Homespun Team" (all builds, no review needed)
                           and adds every App Store Connect user of the team to it
  asc.py wait              waits until the newest build has processed

Reads ASC_KEY_ID and ASC_ISSUER_ID (or ~/.appstoreconnect/homespun.env) and the key from
~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8.
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request

BUNDLE_ID = "photos.homespun.app"
GROUP = "Homespun Team"
API = "https://api.appstoreconnect.apple.com/v1"


def env():
    path = os.path.expanduser("~/.appstoreconnect/homespun.env")
    if os.path.exists(path):
        for line in open(path):
            if "=" in line and not line.startswith("#"):
                key, value = line.strip().split("=", 1)
                os.environ.setdefault(key, value)
    return os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_to_raw(der):
    """ECDSA signature: DER SEQUENCE(r, s) → r || s, 32 bytes each (JWT's ES256 form)."""
    def integer(at):
        assert der[at] == 0x02
        length = der[at + 1]
        value = der[at + 2:at + 2 + length].lstrip(b"\0").rjust(32, b"\0")
        return value, at + 2 + length
    at = 2 if der[1] < 0x80 else 3
    r, at = integer(at)
    s, _ = integer(at)
    return r + s


def token():
    key_id, issuer = env()
    key = os.path.expanduser(os.environ.get("ASC_KEY_PATH", f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"))
    now = int(time.time())
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"}).encode())
    signing_input = header + b"." + claims
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=signing_input,
                         capture_output=True, check=True).stdout
    return (signing_input + b"." + b64(der_to_raw(der))).decode()


def call(method, path, body=None):
    request = urllib.request.Request(path if path.startswith("http") else API + path, method=method,
                                     data=json.dumps(body).encode() if body else None)
    request.add_header("Authorization", "Bearer " + token())
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        sys.exit(f"{method} {path}: {error.code} {detail[:600]}")


def app_id():
    apps = call("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        sys.exit(f"No app with bundle ID {BUNDLE_ID} in App Store Connect.")
    return apps[0]["id"]


def builds(limit=5):
    data = call("GET", f"/builds?filter[app]={app_id()}&sort=-uploadedDate&limit={limit}"
                       "&fields[builds]=version,processingState,uploadedDate,expired,usesNonExemptEncryption")["data"]
    return [(b["attributes"]["version"], b["attributes"]["processingState"], b["attributes"]["uploadedDate"],
             b["id"]) for b in data]


def testers():
    app = app_id()
    groups = call("GET", f"/apps/{app}/betaGroups?limit=50")["data"]
    group = next((g for g in groups if g["attributes"]["name"] == GROUP), None)
    if group is None:
        group = call("POST", "/betaGroups", {"data": {
            "type": "betaGroups",
            "attributes": {"name": GROUP, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]
        print(f"created internal group {GROUP!r}")
    else:
        print(f"internal group {GROUP!r} exists")
    members = {t["attributes"].get("email") for t in
               call("GET", f"/betaGroups/{group['id']}/betaTesters?limit=200")["data"]}
    for user in call("GET", "/users?limit=200")["data"]:
        attributes = user["attributes"]
        email = attributes["username"]
        if email in members:
            print(f"{email}: already a tester")
            continue
        call("POST", "/betaTesters", {"data": {
            "type": "betaTesters",
            "attributes": {"email": email, "firstName": attributes.get("firstName") or "",
                           "lastName": attributes.get("lastName") or ""},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}}}})
        print(f"{email}: added; TestFlight sends an invitation")


def wait():
    while True:
        latest = builds(1)
        if not latest:
            print(f"{time.strftime('%H:%M:%S')} no build yet (Apple is still receiving it)", flush=True)
        else:
            version, state, uploaded, _ = latest[0]
            print(f"{time.strftime('%H:%M:%S')} build {version}: {state}", flush=True)
            if state != "PROCESSING":
                return state
        time.sleep(60)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "builds"
    if command == "builds":
        for version, state, uploaded, _ in builds():
            print(f"{version}  {state:<12} uploaded {uploaded}")
    elif command == "testers":
        testers()
    elif command == "wait":
        sys.exit(0 if wait() == "VALID" else 1)
    else:
        sys.exit(__doc__)
