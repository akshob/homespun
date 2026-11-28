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
# UPGRADE_THEN=ids: after the selected tests pass on OLD_SERVER_FIXTURE, upgrade that server
# in place and run these tests with the same app and simulator. STRICT_SELECTION=1 rejects skips.
set -uo pipefail
source ${0:A:h}/env.sh
NAME=$1 TYPE=$2 ONLY=$3 PORT=$4 POSE=${5:-}
stamp segment.start
timed simulator.slot take_sim_slot
SIM=$(new_simulator $TYPE "HS CI $NAME $PORT") || exit 1
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
    if ! $DUOCTL -d $SIM $POSE; then
        stamp simulator.pose.end
        exit 1
    fi
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
    CURRENT_SERVER_BIN=$SERVER_BIN
    if [[ -n ${OLD_SERVER_FIXTURE:-} ]]; then
        [[ -x $OLD_SERVER_BIN ]] || { echo "the immutable b35fc19 server fixture is missing"; exit 1; }
        SERVER_BIN=$OLD_SERVER_BIN
    fi
    export HOMESPUN_DATA=$DATA HOMESPUN_ORIGINALS=$DATA/originals HOMESPUN_HOST=127.0.0.1 HOMESPUN_PORT=$PORT \
           HOMESPUN_NAME="Home Mac (test)" HOMESPUN_PUBLIC_URL=127.0.0.1:$PORT
    timed server.port wait_port_free $PORT || exit 1
    stamp server.start.start
    CONTROL=$DATA/server-control
    ACTIONFILE=$DATA/host-action
    print online > $CONTROL
    (
        child="" currentData=$DATA currentPort=$PORT currentLog=$DATA.log activeBinary=$SERVER_BIN
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
                $activeBinary serve >> $currentLog 2>&1 & child=$!
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
                        upgrade-server)
                            [[ -n ${OLD_SERVER_FIXTURE:-} ]] || exit 1
                            stamp server.upgrade.start
                            stop_server
                            wait_port_free $currentPort || exit 1
                            activeBinary=$CURRENT_SERVER_BIN
                            start_server || exit 1
                            print upgraded > $DATA/server-upgraded
                            stamp server.upgrade.end;;
                        rotate-key)
                            HOMESPUN_DATA=$currentData $SERVER_BIN certificate --new-key \
                                >> $RESULTS/$NAME-host-actions.log 2>&1;;
                        pairing-code)
                            if HOMESPUN_DATA=$currentData $SERVER_BIN pair --minutes 180 > $DATA/pairing-again.next; then
                                mv $DATA/pairing-again.next $DATA/pairing-again
                            fi;;
                        compact-settled)
                            result=timeout
                            for attempt in {1..900}; do
                                pending=$(sqlite3 -cmd ".timeout 2000" $currentData/homespun.db \
                                    "SELECT count(*) FROM backup_requests WHERE wants_compact = 1 AND paused = 0 AND cancelled = 0 AND compact_state IN ('requested','queued','processing')" 2>/dev/null)
                                ready=$(sqlite3 -cmd ".timeout 2000" $currentData/homespun.db \
                                    "SELECT count(*) FROM backup_requests WHERE compact_state = 'ready'" 2>/dev/null)
                                if [[ $pending == 0 && ${ready:-0} -gt 0 ]]; then result=ready; break; fi
                                sleep 0.2
                            done
                            print -r -- $result > $DATA/compact-settled;;
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
    export TEST_RUNNER_HOMESPUN_SERVER_UPGRADED_FILE=$DATA/server-upgraded
    export TEST_RUNNER_HOMESPUN_MOVED_SERVER=127.0.0.1:$MOVEPORT
    export TEST_RUNNER_HOMESPUN_ROGUE_LOG=$RESULTS/$NAME-rogue-server.log
    export TEST_RUNNER_HOMESPUN_PAIRING_OUTPUT_FILE=$DATA/pairing-again
    export TEST_RUNNER_HOMESPUN_SERVER_LOG=$DATA.log
    export TEST_RUNNER_HOMESPUN_COMPACT_SETTLED_FILE=$DATA/compact-settled
    export TEST_RUNNER_HOMESPUN_SEED_VIDEO_BYTES=$(stat -f%z $SEED/IMG_2003.MOV)
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
    source ${0:A:h}/duo-poses.sh
    ( while true; do
        if [[ -f $POSEFILE ]]; then
          process_duo_pose_request >> $RESULTS/$NAME-poses.log 2>&1
        fi
        sleep 0.5
      done ) & WATCH=$!
    export TEST_RUNNER_DUO_POSE_FILE=$POSEFILE
fi
RESULT=$RESULTS/$NAME.xcresult
LOG=$RESULTS/$NAME.log
QUARANTINED=$RESULTS/$NAME-quarantined.txt
SKIP=($(quarantined $ONLY $QUARANTINED)) || exit 1
run_tests() {
    rm -rf $RESULT
    stamp xcodebuild.start
    TEST_RUNNER_HOMESPUN_SERVER=127.0.0.1:$PORT TEST_RUNNER_HOMESPUN_PAIRING_CODE=$CODE TEST_RUNNER_HOMESPUN_PAIR_LINK="$LINK" \
    TEST_RUNNER_HOMESPUN_REMOVE=1 \
      test_without_building $RESULT ${(@)${(s:,:)ONLY}/#/-only-testing:} $SKIP $(test_retries) \
      2>&1 | tee $LOG | filter
    local code=${pipestatus[1]}
    stamp xcodebuild.end
    return $code
}
run_tests; STATUS=$?
# Now and then the simulator can't start or reach the test runner, and no test runs: once more, rebooted.
if (( STATUS != 0 )) && ! grep -q "^Test Case" $LOG \
    && grep -qE "failed to launch|Failed to establish communication|Channel disconnected|crashed while preparing" $LOG; then
    echo "the test runner didn't start; rebooting the simulator and trying once more"
    stamp simulator.reboot.start
    xcrun simctl shutdown $SIM; xcrun simctl boot $SIM && xcrun simctl bootstatus $SIM -b >/dev/null
    stamp simulator.reboot.end
    run_tests; STATUS=$?
fi
if [[ -z ${SERVERLESS:-} && $ONLY == *HomespunUITests/(ItemViewerUITests|ServerModeUITests|ServerTabUITests|PremiumUITests|DuoLayoutUITests|TelemetryUITests|GridRedrawUITests|BackupResumeUITests|OldServerUITests)* ]]; then
    require_test_environment $LOG || STATUS=1
fi
if [[ -n ${STRICT_SELECTION:-} ]]; then
    require_selected_tests_ran $LOG $ONLY $QUARANTINED || STATUS=1
fi
if [[ -n ${UPGRADE_THEN:-} ]] && (( STATUS == 0 )); then
    [[ -n ${OLD_SERVER_FIXTURE:-} && -z ${SERVERLESS:-} ]] \
      || { echo "error: UPGRADE_THEN requires the isolated old server fixture" >&2; exit 1; }
    rm -f $DATA/server-upgraded
    print upgrade-server > $ACTIONFILE
    upgraded=""
    for attempt in {1..120}; do
        if [[ -f $DATA/server-upgraded ]]; then upgraded=1; break; fi
        kill -0 $SERVER 2>/dev/null || break
        sleep 1
    done
    [[ -n $upgraded ]] || { echo "error: test server did not upgrade within 120 seconds" >&2; exit 1; }
    ONLY=$UPGRADE_THEN
    RESULT=$RESULTS/$NAME-upgraded.xcresult LOG=$RESULTS/$NAME-upgraded.log
    QUARANTINED=$RESULTS/$NAME-upgraded-quarantined.txt
    SKIP=($(quarantined $ONLY $QUARANTINED)) || exit 1
    run_tests; STATUS=$?
    require_test_environment $LOG || STATUS=1
    if [[ -n ${STRICT_SELECTION:-} ]]; then
        require_selected_tests_ran $LOG $ONLY $QUARANTINED || STATUS=1
    fi
fi
if [[ -n ${STUB_PORT:-} ]]; then
    timed telemetry.check python3 ${0:A:h}/telemetry-check.py $STUBLOG "Home Mac" "127.0.0.1:$PORT" "IMG_200" || STATUS=1
fi
exit $STATUS
