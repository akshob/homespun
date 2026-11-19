#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# Compact copies later (CompactLaterUITests): old synthetic media plus two items made today and the
# seed video, against a temporary server; checks what the server's trash holds afterwards.
#   later.sh <name> <device type> <port> [open]
set -uo pipefail
source ${0:A:h}/env.sh
NAME=$1 TYPE=$2 PORT=$3 POSE=${4:-}
stamp segment.start
MEDIA=$CI_STATE/media/later-$PORT; rm -rf $MEDIA; mkdir -p $MEDIA
stamp media.recent.generate.start
ffmpeg -v error -f lavfi -i testsrc2=size=1600x1200 -frames:v 1 -q:v 2 $MEDIA/RECENT_1.JPG
ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=30:duration=2 -c:v libx264 -pix_fmt yuv420p $MEDIA/RECENT_2.MP4
stamp media.recent.generate.end
timed simulator.slot take_sim_slot
SIM=$(new_simulator $TYPE "HS CI $NAME $PORT") || exit 1
DATA=$CI_STATE/servers/$NAME-$PORT; rm -rf $DATA; mkdir -p $DATA/originals
SERVER=""
trap 'stamp cleanup.start; [[ -n $SERVER ]] && { kill $SERVER; wait $SERVER; }; cp $DATA.log $RESULTS/$NAME-server.log 2>/dev/null; remove_simulator $SIM; rm -rf $DATA $MEDIA; stamp cleanup.end; stamp segment.end' EXIT
if [[ -n $POSE ]]; then
    stamp simulator.pose.start
    $DUOCTL -d $SIM $POSE >/dev/null 2>&1
    stamp simulator.pose.end
    timed simulator.pose-wait sleep 15
fi
timed simulator.privacy xcrun simctl privacy $SIM grant photos photos.homespun.app.dev
timed media.seed.add xcrun simctl addmedia $SIM $SEED/IMG_2001.HEIC $SEED/IMG_2001.MOV $SEED/IMG_2002.JPG $SEED/IMG_2003.MOV $MEDIA/RECENT_1.JPG $MEDIA/RECENT_2.MP4
export HOMESPUN_DATA=$DATA HOMESPUN_ORIGINALS=$DATA/originals HOMESPUN_HOST=127.0.0.1 HOMESPUN_PORT=$PORT HOMESPUN_NAME="Home Mac (test)"
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
stamp xcodebuild.start
TEST_RUNNER_HOMESPUN_SERVER=127.0.0.1:$PORT TEST_RUNNER_HOMESPUN_PAIRING_CODE=$CODE TEST_RUNNER_HOMESPUN_RECENT=3 \
  test_without_building $RESULT -only-testing:HomespunUITests/CompactLaterUITests $(test_retries) \
  2>&1 | tee $RESULTS/$NAME.log | filter
STATUS=${pipestatus[1]}
stamp xcodebuild.end
require_test_environment $RESULTS/$NAME.log || STATUS=1
echo "server trash: $(find $DATA/originals/.trash -type f 2>/dev/null | wc -l | tr -d " ") file(s); stored: $(find $DATA/originals -type f -not -path "*/.trash/*" | wc -l | tr -d " ")"
exit $STATUS
