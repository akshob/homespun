#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
if [[ $# != 1 || ! -d $1 ]]; then
    echo "Usage: demo-upload.sh LOCAL_FOLDER (contains manifest.json and 16 processed photos)" >&2
    exit 2
fi
folder=$(cd "$1" && pwd)
# Validate before making any remote changes; publish the manifest last.
mapfile -t files < <(python3 - "$folder" <<'PY'
import hashlib, json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
m = json.loads((root / "manifest.json").read_text())
assert set(m) == {"version", "totalBytes", "files"} and m["version"] == 1
assert len(m["files"]) == 16 and len({f["file"] for f in m["files"]}) == 16
assert sum(f["size"] for f in m["files"]) == m["totalBytes"] <= 64 * 1024 * 1024
for f in m["files"]:
    assert set(f) == {"file", "sha256", "size", "kind", "width", "height", "date", "category"}
    assert re.fullmatch(r"demo-[a-z0-9-]+\.(heic|jpg)", f["file"])
    p = root / f["file"]
    assert not p.is_symlink() and p.is_file()
    assert 0 < f["size"] <= 8 * 1024 * 1024 and p.stat().st_size == f["size"]
    assert hashlib.sha256(p.read_bytes()).hexdigest() == f["sha256"]
    assert f["kind"] == "photo" and 0 < f["width"] <= 4032 and 0 < f["height"] <= 4032
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)", f["date"])
    assert re.fullmatch(r"[a-z-]{1,40}", f["category"])
for f in m["files"]:
    print(f["file"])
PY
)
[[ ${#files[@]} == 16 ]] || { echo "Invalid manifest; nothing uploaded" >&2; exit 1; }
for file in "${files[@]}"; do
    wrangler r2 object put "homespun-demo/v1/$file" --remote --file "$folder/$file" >/dev/null
done
wrangler r2 object put homespun-demo/v1/manifest.json --remote --file "$folder/manifest.json" --content-type application/json >/dev/null
echo "Uploaded 16 private demo photos and manifest. No public access was enabled."
