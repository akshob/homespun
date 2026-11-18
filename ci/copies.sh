#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# Compact copies made elsewhere (CopyFinderUITests): the seed media stand in for copies made with
# another tool; their "originals" (the same bytes plus a suffix) are imported into a temporary
# server with `homespun-server import`, and the app finds them.
#   copies.sh <name> <port>
set -uo pipefail
source ${0:A:h}/env.sh
NAME=$1 PORT=$2
stamp segment.start
timed simulator.slot take_sim_slot
SIM=$(new_simulator iPhone-18-Pro "HS CI $NAME $PORT")
DATA=$CI_STATE/servers/$NAME-$PORT ORIG=$CI_STATE/servers/$NAME-$PORT-originals
rm -rf $DATA $ORIG; mkdir -p $DATA/originals $ORIG
SERVER=""
trap 'stamp cleanup.start; [[ -n $SERVER ]] && { kill $SERVER; wait $SERVER; }; cp $DATA.log $RESULTS/$NAME-server.log 2>/dev/null; remove_simulator $SIM; rm -rf $DATA $ORIG; stamp cleanup.end; stamp segment.end' EXIT
timed simulator.privacy xcrun simctl privacy $SIM grant photos photos.homespun.app.dev
timed media.seed.add xcrun simctl addmedia $SIM $SEED/IMG_2001.HEIC $SEED/IMG_2001.MOV $SEED/IMG_2002.JPG $SEED/IMG_2003.MOV
stamp media.copies.generate.start
for f in IMG_2001.HEIC IMG_2001.MOV IMG_2002.JPG IMG_2003.MOV; do cat $SEED/$f > $ORIG/$f; printf 'original' >> $ORIG/$f; done
h() { shasum -a 256 $SEED/$1 | cut -d" " -f1 }
cat > $DATA/copies.jsonl <<JSONL
{"kind":"live_photo","originals":[{"role":"photo","path":"$ORIG/IMG_2001.HEIC"},{"role":"paired_video","path":"$ORIG/IMG_2001.MOV"}],"copies":[{"role":"photo","sha256":"$(h IMG_2001.HEIC)"},{"role":"paired_video","sha256":"$(h IMG_2001.MOV)"}]}
{"kind":"photo","originals":[{"role":"photo","path":"$ORIG/IMG_2002.JPG"}],"copies":[{"role":"photo","sha256":"$(h IMG_2002.JPG)"}]}
{"kind":"video","originals":[{"role":"video","path":"$ORIG/IMG_2003.MOV"}],"copies":[{"role":"video","sha256":"$(h IMG_2003.MOV)"}]}
JSONL
stamp media.copies.generate.end
export HOMESPUN_DATA=$DATA HOMESPUN_ORIGINALS=$DATA/originals HOMESPUN_HOST=127.0.0.1 HOMESPUN_PORT=$PORT HOMESPUN_NAME="Home Mac (copies)"
timed server.import $SERVER_BIN import $DATA/copies.jsonl
timed server.port wait_port_free $PORT || exit 1
stamp server.start.start
$SERVER_BIN serve > $DATA.log 2>&1 &
SERVER=$!
stamp server.start.end
timed server.ready wait_for_server $PORT || exit 1
kill -0 $SERVER 2>/dev/null || { echo "the test server didn't start"; cat $DATA.log; exit 1; }
CODE=$(timed server.pair pairing_output | sed -n "s/^Pairing code: \([A-Z0-9-]*\).*/\1/p")
[[ -n $CODE ]] || { echo "no pairing code"; exit 1; }
RESULT=$RESULTS/$NAME.xcresult; rm -rf $RESULT
cd $APP
stamp xcodebuild.start
TEST_RUNNER_HOMESPUN_SERVER=127.0.0.1:$PORT TEST_RUNNER_HOMESPUN_PAIRING_CODE=$CODE TEST_RUNNER_HOMESPUN_COPIES=3 \
  xcodebuild test-without-building -project Homespun.xcodeproj -scheme Homespun -destination id=$SIM -derivedDataPath $DD \
  -resultBundlePath $RESULT -only-testing:HomespunUITests/CopyFinderUITests $(test_retries) 2>&1 | tee $RESULTS/$NAME.log | filter
STATUS=${pipestatus[1]}
stamp xcodebuild.end
exit $STATUS
