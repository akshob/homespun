#!/bin/zsh
# Compact copies later (CompactLaterUITests): old synthetic media plus two items made today and the
# seed video, against a temporary server; checks what the server's trash holds afterwards.
#   later.sh <name> <device type> <port> [open]
set -uo pipefail
source ${0:A:h}/env.sh
NAME=$1 TYPE=$2 PORT=$3 POSE=${4:-}
MEDIA=$CI_STATE/media/later-$PORT; rm -rf $MEDIA; mkdir -p $MEDIA
ffmpeg -v error -f lavfi -i testsrc2=size=1600x1200 -frames:v 1 -q:v 2 $MEDIA/RECENT_1.JPG
ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=30:duration=2 -c:v libx264 -pix_fmt yuv420p $MEDIA/RECENT_2.MP4
take_sim_slot
SIM=$(new_simulator $TYPE "HS CI $NAME $PORT")
DATA=$CI_STATE/servers/$NAME-$PORT; rm -rf $DATA; mkdir -p $DATA/originals
SERVER=""
trap '[[ -n $SERVER ]] && kill $SERVER; cp $DATA.log $RESULTS/$NAME-server.log 2>/dev/null; remove_simulator $SIM; rm -rf $DATA $MEDIA' EXIT
if [[ -n $POSE ]]; then $DUOCTL -d $SIM $POSE >/dev/null 2>&1; sleep 15; fi
xcrun simctl privacy $SIM grant photos photos.homespun.app.dev
xcrun simctl addmedia $SIM $SEED/IMG_2001.HEIC $SEED/IMG_2001.MOV $SEED/IMG_2002.JPG $SEED/IMG_2003.MOV $MEDIA/RECENT_1.JPG $MEDIA/RECENT_2.MP4
export HOMESPUN_DATA=$DATA HOMESPUN_ORIGINALS=$DATA/originals HOMESPUN_HOST=127.0.0.1 HOMESPUN_PORT=$PORT HOMESPUN_NAME="polonium (test)"
$SERVER_BIN serve > $DATA.log 2>&1 &
SERVER=$!; sleep 3
CODE=$($SERVER_BIN pair --minutes 180 | sed -n "s/^Pairing code: \([A-Z0-9-]*\).*/\1/p")
RESULT=$RESULTS/$NAME.xcresult; rm -rf $RESULT
cd $APP
TEST_RUNNER_HOMESPUN_SERVER=127.0.0.1:$PORT TEST_RUNNER_HOMESPUN_PAIRING_CODE=$CODE TEST_RUNNER_HOMESPUN_RECENT=3 \
  xcodebuild test-without-building -project Homespun.xcodeproj -scheme Homespun -destination id=$SIM -derivedDataPath $DD \
  -resultBundlePath $RESULT -only-testing:HomespunUITests/CompactLaterUITests 2>&1 | tee $RESULTS/$NAME.log | filter
STATUS=${pipestatus[1]}
echo "server trash: $(find $DATA/originals/.trash -type f 2>/dev/null | wc -l | tr -d " ") file(s); stored: $(find $DATA/originals -type f -not -path "*/.trash/*" | wc -l | tr -d " ")"
exit $STATUS
