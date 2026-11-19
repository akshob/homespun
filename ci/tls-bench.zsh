#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# Opt-in HTTPS upload measurement against a fresh server, never an installed service.
set -euo pipefail
source ${0:A:h}/env.sh
PORT=${TLS_BENCH_PORT:-18787}
[[ $PORT == <-> ]] && (( PORT > 1024 && PORT <= 65535 && PORT != 8787 )) \
    || { echo "Choose a test port from 1025 to 65535, other than 8787."; exit 2; }
DATA=$CI_STATE/tls-bench-$(uuidgen)
mkdir -p $DATA/originals
export HOMESPUN_DATA=$DATA HOMESPUN_ORIGINALS=$DATA/originals HOMESPUN_HOST=127.0.0.1 HOMESPUN_PORT=$PORT \
       HOMESPUN_PUBLIC_URL=127.0.0.1:$PORT HOMESPUN_NAME="TLS benchmark"
SERVER=""
cleanup() {
    [[ -z $SERVER ]] || { kill $SERVER 2>/dev/null || true; wait $SERVER 2>/dev/null || true; }
    rm -rf $DATA
}
trap cleanup EXIT
wait_port_free $PORT
$SERVER_BIN serve > $DATA/server.log 2>&1 & SERVER=$!
wait_for_server $PORT
kill -0 $SERVER
PIN=$(openssl x509 -in $DATA/tls/certificate.pem -pubkey -noout | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256 -binary | openssl base64 -A)
BASE=https://127.0.0.1:$PORT/api/v1
https() { curl -fsSk --pinnedpubkey "sha256//$PIN" "$@"; }
CODE=$(pairing_output | sed -n 's/^Pairing code: \([A-Z0-9-]*\).*/\1/p')
NONCE=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(https -H 'Content-Type: application/json' --data-binary "{\"nonce\":\"$NONCE\"}" $BASE/pair/challenge \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
# The curl SPKI pin authenticated the key before this code is sent.
TOKEN=$(https -H 'Content-Type: application/json' \
    --data-binary "{\"code\":\"$CODE\",\"device_name\":\"Benchmark\",\"challenge\":\"$CHALLENGE\"}" $BASE/pair \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
python3 - $DATA/payload.bin <<'PY'
import os, sys
with open(sys.argv[1], "wb") as file:
    for _ in range(128):
        file.write(os.urandom(8 << 20))
PY
HASH=$(python3 - $DATA/payload.bin <<'PY'
import hashlib, sys
digest = hashlib.sha256()
with open(sys.argv[1], "rb") as file:
    while chunk := file.read(8 << 20):
        digest.update(chunk)
print(digest.hexdigest())
PY
)
https -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data-binary "{\"kind\":\"photo\",\"compact\":false,\"resources\":[{\"role\":\"photo\",\"filename\":\"payload.bin\",\"size\":1073741824,\"sha256\":\"$HASH\"}]}" \
    $BASE/assets > $DATA/registered.json
START=$(python3 -c 'import time; print(time.monotonic())')
for index in {0..127}; do
    dd if=$DATA/payload.bin of=$DATA/chunk bs=8388608 skip=$index count=1 2>/dev/null
    https -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/octet-stream' \
        --data-binary @$DATA/chunk "$BASE/assets/$HASH/resources/photo?offset=$((index * 8388608))" > $DATA/upload.json
done
python3 - $START <<'PY'
import sys, time
seconds = time.monotonic() - float(sys.argv[1])
print(f"HTTPS upload: 1024 MiB in {seconds:.2f}s, {1024 / seconds:.1f} MiB/s")
PY
