#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# UI tests on a fresh simulator against a temporary Homespun Server (its own data, originals and
# port; never the real server's).
#
#   ui.sh <name> <device type> <only-testing ids, comma-separated> <port> [open]
#
# Environment: EXTRA=n adds n small synthetic photos, DATED=n as many taken over the past months
# (12 a month); DUO_POSES=1 lets the test fold and turn the
# Duo (it writes a pose to TEST_RUNNER_DUO_POSE_FILE; screenshots go to $RESULTS/<name>-shots);
# STUB_PORT=p sends telemetry to a local stub and checks what arrived. SERVERLESS=1 (Try the Demo): no
# temporary server, and no Photos access, so iOS would ask if anything needed it.
set -uo pipefail
source ${0:A:h}/env.sh
NAME=$1 TYPE=$2 ONLY=$3 PORT=$4 POSE=${5:-}
stamp segment.start
timed simulator.slot take_sim_slot
SIM=$(new_simulator $TYPE "HS CI $NAME $PORT")
DATA=$CI_STATE/servers/$NAME-$PORT; rm -rf $DATA; mkdir -p $DATA/originals
PIDFILE=$DATA/server.pid
MOVEPORT=$(( PORT + 1000 ))
SERVER="" STUB="" WATCH=""
cleanup() {
    stamp cleanup.start
    [[ -n $WATCH ]] && kill $WATCH 2>/dev/null
    [[ -n $SERVER ]] && kill $SERVER 2>/dev/null
    [[ -n $STUB ]] && kill $STUB 2>/dev/null
    if [[ -f $PIDFILE ]]; then
        current=$(cat $PIDFILE 2>/dev/null)
        if [[ -n $current ]]; then
            kill $current 2>/dev/null
            for attempt in {1..100}; do kill -0 $current 2>/dev/null || break; sleep 0.1; done
            kill -0 $current 2>/dev/null && kill -KILL $current 2>/dev/null
        fi
    fi
    [[ -n $SERVER ]] && wait $SERVER 2>/dev/null
    cp $DATA.log $RESULTS/$NAME-server.log 2>/dev/null
    remove_simulator $SIM
    rm -rf $DATA
    stamp cleanup.end
    stamp segment.end
}
trap cleanup EXIT
[[ -z ${SERVERLESS:-} ]] && timed simulator.privacy xcrun simctl privacy $SIM grant photos photos.homespun.app.dev
# iPhone Duo starts closed (the cover); "open" unfolds it first.
if [[ -n $POSE ]]; then
    stamp simulator.pose.start
    $DUOCTL -d $SIM $POSE >/dev/null 2>&1
    stamp simulator.pose.end
    timed simulator.pose-wait sleep 15
fi
timed media.seed.add xcrun simctl addmedia $SIM $SEED/IMG_2001.HEIC $SEED/IMG_2001.MOV $SEED/IMG_2002.JPG $SEED/IMG_2003.MOV
if [[ -n ${EXTRA:-} ]]; then
    MEDIA=$CI_STATE/media/extra-3000
    stamp media.extra.generate.start
    if [[ ! -f $MEDIA/.done ]]; then
        mkdir -p $MEDIA && ffmpeg -v error -f lavfi -i "testsrc2=size=320x240:rate=1" -frames:v 3000 -q:v 6 $MEDIA/IMG_%05d.JPG \
          && touch $MEDIA/.done
    fi
    stamp media.extra.generate.end
    timed media.extra.add xcrun simctl addmedia $SIM $(ls $MEDIA/*.JPG | head -$EXTRA)
fi
if [[ -n ${DATED:-} ]]; then
    MEDIA=$CI_STATE/media/dated-$DATED
    stamp media.dated.generate.start
    [[ -f $MEDIA/.done ]] || { swift ${0:A:h}/dated-photos.swift $MEDIA $DATED && touch $MEDIA/.done; }
    stamp media.dated.generate.end
    timed media.dated.add xcrun simctl addmedia $SIM $MEDIA/*.JPG
fi
CODE="" LINK=""
if [[ -z ${SERVERLESS:-} ]]; then
    export HOMESPUN_DATA=$DATA HOMESPUN_ORIGINALS=$DATA/originals HOMESPUN_HOST=127.0.0.1 HOMESPUN_PORT=$PORT \
           HOMESPUN_NAME="Home Mac (test)" HOMESPUN_PUBLIC_URL=127.0.0.1:$PORT
    timed server.port wait_port_free $PORT || exit 1
    stamp server.start.start
    CONTROL=$DATA/server-control
    ACTIONFILE=$DATA/host-action
    print online > $CONTROL
    (
        child="" currentData=$DATA currentPort=$PORT currentLog=$DATA.log
        stop_server() {
            [[ -z $child ]] && return
            kill $child 2>/dev/null
            for attempt in {1..100}; do kill -0 $child 2>/dev/null || break; sleep 0.1; done
            kill -0 $child 2>/dev/null && kill -KILL $child 2>/dev/null
            wait $child 2>/dev/null
            child=""
            rm -f $PIDFILE
        }
        start_server() {
            mkdir -p $currentData/originals
            HOMESPUN_DATA=$currentData HOMESPUN_ORIGINALS=$currentData/originals \
                HOMESPUN_PORT=$currentPort HOMESPUN_PUBLIC_URL=127.0.0.1:$currentPort \
                $SERVER_BIN serve >> $currentLog 2>&1 & child=$!
            print -r -- $child > $PIDFILE
            HOMESPUN_DATA=$currentData wait_for_server $currentPort
        }
        trap stop_server EXIT
        trap 'exit 0' TERM INT
        while true; do
            wanted=$(cat $CONTROL)
            if [[ $wanted == offline ]]; then
                stop_server
                print offline > $CONTROL.ack
            elif [[ $wanted == online ]]; then
                [[ -n $child ]] || start_server || exit 1
                print online > $CONTROL.ack
                if [[ -f $ACTIONFILE ]]; then
                    case $(cat $ACTIONFILE) in
                        rotate-key)
                            HOMESPUN_DATA=$currentData $SERVER_BIN certificate --new-key \
                                >> $RESULTS/$NAME-host-actions.log 2>&1;;
                        pairing-code)
                            if HOMESPUN_DATA=$currentData $SERVER_BIN pair --minutes 180 > $DATA/pairing-again.next; then
                                mv $DATA/pairing-again.next $DATA/pairing-again
                            fi;;
                        wrong-key-port)
                            stop_server
                            wait_port_free $MOVEPORT || exit 1
                            currentData=$DATA/rogue currentPort=$MOVEPORT currentLog=$RESULTS/$NAME-rogue-server.log
                            start_server || exit 1;;
                        move-port)
                            stop_server
                            wait_port_free $MOVEPORT || exit 1
                            currentData=$DATA currentPort=$MOVEPORT currentLog=$DATA.log
                            start_server || exit 1;;
                    esac
                    rm -f $ACTIONFILE
                fi
            fi
            sleep 0.2
        done
    ) &
    SERVER=$!
    stamp server.start.end
    export TEST_RUNNER_SERVER_CONTROL_FILE=$CONTROL
    timed server.ready wait_for_server $PORT || exit 1
    # The server answering is this one (not one still stopping from an earlier try).
    kill -0 $SERVER 2>/dev/null || { echo "the test server didn't start"; cat $DATA.log; exit 1; }
    OUT=$(timed server.pair pairing_output) || { echo "no pairing code"; exit 1; }
    CODE=$(echo "$OUT" | sed -n "s/^Pairing code: \([A-Z0-9-]*\).*/\1/p"); LINK=$(echo "$OUT" | grep -o "homespun://pair[^ ]*" | head -1)
    export TEST_RUNNER_HOMESPUN_HOST_ACTION_FILE=$ACTIONFILE
    export TEST_RUNNER_HOMESPUN_MOVED_SERVER=127.0.0.1:$MOVEPORT
    export TEST_RUNNER_HOMESPUN_ROGUE_LOG=$RESULTS/$NAME-rogue-server.log
    export TEST_RUNNER_HOMESPUN_PAIRING_OUTPUT_FILE=$DATA/pairing-again
fi
if [[ -n ${STUB_PORT:-} ]]; then
    stamp telemetry.start.start
    STUBLOG=$DATA/telemetry.jsonl; : > $STUBLOG
    python3 ${0:A:h}/telemetry-stub.py $STUB_PORT $STUBLOG & STUB=$!; sleep 1
    export TEST_RUNNER_TELEMETRY_STUB=http://127.0.0.1:$STUB_PORT
    stamp telemetry.start.end
fi
if [[ -n ${DUO_POSES:-} ]]; then
    POSEFILE=$DATA/pose-request; SHOTS=$RESULTS/$NAME-shots; rm -rf $SHOTS; mkdir -p $SHOTS
    pose_call() { timed "pose.$1" $DUOCTL -d $SIM "$@"; }
    turn() { for i in 1 2 3 4; do pose_call rotate $1 && return; sleep 3; done; }
    ( while true; do
        if [[ -f $POSEFILE ]]; then
          {
            n=$(cat $POSEFILE)
            print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) request: $n"
            stamp pose.request.start
            case $n in
              shot\ *) pose_call screenshot "$SHOTS/${n#shot }.png";;
              landscape) pose_call hinge 180; turn landscape;;
              portrait) pose_call hinge 180; turn portrait;;
              laptop) pose_call hinge 180; turn portrait; pose_call hinge 100;;
              folded) pose_call hinge 0; timed pose.fold-wait sleep 2; turn portrait;;
              swipe\ *) read -r command x1 y1 x2 y2 < $POSEFILE; pose_call swipe $x1 $y1 $x2 $y2;;
            esac
            stamp pose.request.end
          } >> $RESULTS/$NAME-poses.log 2>&1
          rm -f $POSEFILE
        fi
        sleep 0.5
      done ) & WATCH=$!
    export TEST_RUNNER_DUO_POSE_FILE=$POSEFILE
fi
RESULT=$RESULTS/$NAME.xcresult
SKIP=($(quarantined $ONLY $RESULTS/$NAME-quarantined.txt))
cd $APP
run_tests() {
    rm -rf $RESULT
    stamp xcodebuild.start
    TEST_RUNNER_HOMESPUN_SERVER=127.0.0.1:$PORT TEST_RUNNER_HOMESPUN_PAIRING_CODE=$CODE TEST_RUNNER_HOMESPUN_PAIR_LINK="$LINK" \
    TEST_RUNNER_HOMESPUN_REMOVE=1 \
      xcodebuild test-without-building -project Homespun.xcodeproj -scheme Homespun -destination id=$SIM -derivedDataPath $DD \
      -resultBundlePath $RESULT ${(@)${(s:,:)ONLY}/#/-only-testing:} $SKIP $(test_retries) 2>&1 | tee $RESULTS/$NAME.log | filter
    local code=${pipestatus[1]}
    stamp xcodebuild.end
    return $code
}
run_tests; STATUS=$?
# Now and then the simulator can't start or reach the test runner, and no test runs: once more, rebooted.
if (( STATUS != 0 )) && ! grep -q "^Test Case" $RESULTS/$NAME.log \
    && grep -qE "failed to launch|Failed to establish communication|Channel disconnected|crashed while preparing" $RESULTS/$NAME.log; then
    echo "the test runner didn't start; rebooting the simulator and trying once more"
    stamp simulator.reboot.start
    xcrun simctl shutdown $SIM; xcrun simctl boot $SIM && xcrun simctl bootstatus $SIM -b >/dev/null
    stamp simulator.reboot.end
    run_tests; STATUS=$?
fi
if [[ -n ${STUB_PORT:-} ]]; then
    timed telemetry.check python3 ${0:A:h}/telemetry-check.py $STUBLOG "Home Mac" "127.0.0.1:$PORT" "IMG_200" || STATUS=1
fi
exit $STATUS
