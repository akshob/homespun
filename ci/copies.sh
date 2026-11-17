#!/bin/zsh
# Compact copies made elsewhere (CopyFinderUITests): the seed media stand in for copies made with
# another tool; their "originals" (the same bytes plus a suffix) are imported into a temporary
# server with `homespun-server import`, and the app finds them.
#   copies.sh <name> <port>
set -uo pipefail
source ${0:A:h}/env.sh
NAME=$1 PORT=$2
take_sim_slot
SIM=$(new_simulator iPhone-18-Pro "HS CI $NAME $PORT")
DATA=$CI_STATE/servers/$NAME-$PORT ORIG=$CI_STATE/servers/$NAME-$PORT-originals
rm -rf $DATA $ORIG; mkdir -p $DATA/originals $ORIG
SERVER=""
trap '[[ -n $SERVER ]] && kill $SERVER; cp $DATA.log $RESULTS/$NAME-server.log 2>/dev/null; remove_simulator $SIM; rm -rf $DATA $ORIG' EXIT
xcrun simctl privacy $SIM grant photos photos.homespun.app.dev
xcrun simctl addmedia $SIM $SEED/IMG_2001.HEIC $SEED/IMG_2001.MOV $SEED/IMG_2002.JPG $SEED/IMG_2003.MOV
for f in IMG_2001.HEIC IMG_2001.MOV IMG_2002.JPG IMG_2003.MOV; do cat $SEED/$f > $ORIG/$f; printf 'original' >> $ORIG/$f; done
h() { shasum -a 256 $SEED/$1 | cut -d" " -f1 }
cat > $DATA/copies.jsonl <<JSONL
{"kind":"live_photo","originals":[{"role":"photo","path":"$ORIG/IMG_2001.HEIC"},{"role":"paired_video","path":"$ORIG/IMG_2001.MOV"}],"copies":[{"role":"photo","sha256":"$(h IMG_2001.HEIC)"},{"role":"paired_video","sha256":"$(h IMG_2001.MOV)"}]}
{"kind":"photo","originals":[{"role":"photo","path":"$ORIG/IMG_2002.JPG"}],"copies":[{"role":"photo","sha256":"$(h IMG_2002.JPG)"}]}
{"kind":"video","originals":[{"role":"video","path":"$ORIG/IMG_2003.MOV"}],"copies":[{"role":"video","sha256":"$(h IMG_2003.MOV)"}]}
JSONL
export HOMESPUN_DATA=$DATA HOMESPUN_ORIGINALS=$DATA/originals HOMESPUN_HOST=127.0.0.1 HOMESPUN_PORT=$PORT HOMESPUN_NAME="Home Mac (copies)"
$SERVER_BIN import $DATA/copies.jsonl
$SERVER_BIN serve > $DATA.log 2>&1 &
SERVER=$!
wait_for_server $PORT || exit 1
CODE=$(pairing_output | sed -n "s/^Pairing code: \([A-Z0-9-]*\).*/\1/p")
[[ -n $CODE ]] || { echo "no pairing code"; exit 1; }
RESULT=$RESULTS/$NAME.xcresult; rm -rf $RESULT
cd $APP
TEST_RUNNER_HOMESPUN_SERVER=127.0.0.1:$PORT TEST_RUNNER_HOMESPUN_PAIRING_CODE=$CODE TEST_RUNNER_HOMESPUN_COPIES=3 \
  xcodebuild test-without-building -project Homespun.xcodeproj -scheme Homespun -destination id=$SIM -derivedDataPath $DD \
  -resultBundlePath $RESULT -only-testing:HomespunUITests/CopyFinderUITests 2>&1 | tee $RESULTS/$NAME.log | filter
exit ${pipestatus[1]}
