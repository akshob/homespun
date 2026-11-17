#!/bin/zsh
# UI tests on a fresh simulator against a temporary Homespun Server (its own data, originals and
# port; never the real server's).
#
#   ui.sh <name> <device type> <only-testing ids, comma-separated> <port> [open]
#
# Environment: EXTRA=n adds n small synthetic photos, DATED=n as many taken over the past months
# (12 a month); DUO_POSES=1 lets the test fold and turn the
# Duo (it writes a pose to TEST_RUNNER_DUO_POSE_FILE; screenshots go to $RESULTS/<name>-shots);
# STUB_PORT=p sends telemetry to a local stub and checks what arrived.
set -uo pipefail
source ${0:A:h}/env.sh
NAME=$1 TYPE=$2 ONLY=$3 PORT=$4 POSE=${5:-}
take_sim_slot
SIM=$(new_simulator $TYPE "HS CI $NAME $PORT")
DATA=$CI_STATE/servers/$NAME-$PORT; rm -rf $DATA; mkdir -p $DATA/originals
SERVER="" STUB="" WATCH=""
cleanup() {
    [[ -n $WATCH ]] && kill $WATCH 2>/dev/null
    [[ -n $STUB ]] && kill $STUB 2>/dev/null
    [[ -n $SERVER ]] && kill $SERVER 2>/dev/null
    cp $DATA.log $RESULTS/$NAME-server.log 2>/dev/null
    remove_simulator $SIM
    rm -rf $DATA
}
trap cleanup EXIT
xcrun simctl privacy $SIM grant photos photos.homespun.app.dev
# iPhone Duo starts closed (the cover); "open" unfolds it first.
if [[ -n $POSE ]]; then $DUOCTL -d $SIM $POSE >/dev/null 2>&1; sleep 15; fi
xcrun simctl addmedia $SIM $SEED/IMG_2001.HEIC $SEED/IMG_2001.MOV $SEED/IMG_2002.JPG $SEED/IMG_2003.MOV
if [[ -n ${EXTRA:-} ]]; then
    MEDIA=$CI_STATE/media/extra-3000
    if [[ ! -f $MEDIA/.done ]]; then
        mkdir -p $MEDIA && ffmpeg -v error -f lavfi -i "testsrc2=size=320x240:rate=1" -frames:v 3000 -q:v 6 $MEDIA/IMG_%05d.JPG \
          && touch $MEDIA/.done
    fi
    xcrun simctl addmedia $SIM $(ls $MEDIA/*.JPG | head -$EXTRA)
fi
if [[ -n ${DATED:-} ]]; then
    MEDIA=$CI_STATE/media/dated-$DATED
    [[ -f $MEDIA/.done ]] || { swift ${0:A:h}/dated-photos.swift $MEDIA $DATED && touch $MEDIA/.done; }
    xcrun simctl addmedia $SIM $MEDIA/*.JPG
fi
export HOMESPUN_DATA=$DATA HOMESPUN_ORIGINALS=$DATA/originals HOMESPUN_HOST=127.0.0.1 HOMESPUN_PORT=$PORT \
       HOMESPUN_NAME="Home Mac (test)" HOMESPUN_PUBLIC_URL=http://127.0.0.1:$PORT
$SERVER_BIN serve > $DATA.log 2>&1 &
SERVER=$!; sleep 3
# Codes last 10 minutes; a run can spend longer than that before its first test pairs.
OUT=$($SERVER_BIN pair --minutes 180)
CODE=$(echo "$OUT" | sed -n "s/^Pairing code: \([A-Z0-9-]*\).*/\1/p"); LINK=$(echo "$OUT" | grep -o "homespun://pair[^ ]*" | head -1)
if [[ -n ${STUB_PORT:-} ]]; then
    STUBLOG=$DATA/telemetry.jsonl; : > $STUBLOG
    python3 ${0:A:h}/telemetry-stub.py $STUB_PORT $STUBLOG & STUB=$!; sleep 1
    export TEST_RUNNER_TELEMETRY_STUB=http://127.0.0.1:$STUB_PORT
fi
if [[ -n ${DUO_POSES:-} ]]; then
    POSEFILE=$DATA/pose-request; SHOTS=$RESULTS/$NAME-shots; rm -rf $SHOTS; mkdir -p $SHOTS
    turn() { for i in 1 2 3 4; do $DUOCTL -d $SIM rotate $1 && return; sleep 3; done; }
    ( while true; do
        if [[ -f $POSEFILE ]]; then
          case $(cat $POSEFILE) in
            shot\ *) n=$(cat $POSEFILE); $DUOCTL -d $SIM screenshot "$SHOTS/${n#shot }.png";;
            landscape) $DUOCTL -d $SIM hinge 180; turn landscape;;
            portrait) $DUOCTL -d $SIM hinge 180; turn portrait;;
            laptop) $DUOCTL -d $SIM hinge 180; turn portrait; $DUOCTL -d $SIM hinge 100;;
            folded) $DUOCTL -d $SIM hinge 0; sleep 2; turn portrait;;
          esac >> $DATA.poses 2>&1
          rm -f $POSEFILE
        fi
        sleep 0.5
      done ) & WATCH=$!
    export TEST_RUNNER_DUO_POSE_FILE=$POSEFILE
fi
RESULT=$RESULTS/$NAME.xcresult; rm -rf $RESULT
cd $APP
TEST_RUNNER_HOMESPUN_SERVER=127.0.0.1:$PORT TEST_RUNNER_HOMESPUN_PAIRING_CODE=$CODE TEST_RUNNER_HOMESPUN_PAIR_LINK="$LINK" \
TEST_RUNNER_HOMESPUN_REMOVE=1 \
  xcodebuild test-without-building -project Homespun.xcodeproj -scheme Homespun -destination id=$SIM -derivedDataPath $DD \
  -resultBundlePath $RESULT ${(@)${(s:,:)ONLY}/#/-only-testing:} 2>&1 | tee $RESULTS/$NAME.log | filter
STATUS=${pipestatus[1]}
if [[ -n ${STUB_PORT:-} ]]; then
    python3 ${0:A:h}/telemetry-check.py $STUBLOG "Home Mac" "127.0.0.1:$PORT" "IMG_200" || STATUS=1
fi
exit $STATUS
