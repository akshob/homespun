#!/bin/zsh
# Performance: unit budgets (Profile build), the UI budgets on the 35,000-photo iPhone Duo simulator
# (setup-perf-sim.sh makes it once), launch time, and a library of 3,000 items opening and paging.
set -u
source ${0:A:h}/env.sh
PERF_DD=$CI_STATE/dd-profile
PERF_SIM=$(cat $CI_STATE/perf-udid 2>/dev/null) || { echo "No performance simulator: run ci/setup-perf-sim.sh once."; exit 1; }
# Its slot ends with the script, so the simulator shuts down too.
SERVER_PID=""
cleanup() {
    xcrun simctl shutdown $PERF_SIM 2>/dev/null
    [[ -z $SERVER_PID ]] || { kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; }
    [[ -z ${BACKUP_DATA:-} ]] || rm -rf $BACKUP_DATA
}
trap cleanup EXIT
failed=()
cd $APP && xcodegen generate --quiet
echo "::group::build (Profile)"
xcodebuild build-for-testing -project Homespun.xcodeproj -scheme HomespunPerf -configuration Profile -destination id=$PERF_SIM \
  -derivedDataPath $PERF_DD -clonedSourcePackagesDirPath $CI_STATE/spm 2>&1 | filter
(( ${pipestatus[1]} == 0 )) || exit 1
specs=($PERF_DD/Build/Products/HomespunPerf_*iphonesimulator*.xctestrun(N))
PERF_RUN=${specs[1]:-}
[[ -f $PERF_RUN ]] || { echo "error: no performance runner configuration"; exit 1; }
echo "::endgroup::"
echo "::group::backup budget server"
(cd $ROOT && swift build -c release --product homespun-server) || exit 1
SERVER_BIN=$ROOT/.build/release/homespun-server
BACKUP_DATA=$CI_STATE/servers/perf-backup-$$
mkdir -p $BACKUP_DATA/originals
export HOMESPUN_DATA=$BACKUP_DATA HOMESPUN_ORIGINALS=$BACKUP_DATA/originals HOMESPUN_HOST=127.0.0.1 HOMESPUN_PORT=18808
wait_port_free $HOMESPUN_PORT || exit 1
$SERVER_BIN serve > $RESULTS/perf-backup-server.log 2>&1 & SERVER_PID=$!
wait_for_server $HOMESPUN_PORT || exit 1
pair=$(pairing_output) || exit 1
export TEST_RUNNER_HOMESPUN_SERVER=127.0.0.1:$HOMESPUN_PORT
export TEST_RUNNER_HOMESPUN_PAIRING_CODE=$(print -r -- $pair | sed -n 's/^Pairing code: \([A-Z0-9-]*\).*/\1/p' | head -1)
[[ -n $TEST_RUNNER_HOMESPUN_PAIRING_CODE ]] || { echo "error: no backup budget pairing code"; exit 1; }
echo "::endgroup::"
take_sim_slot
echo "::group::unit budgets"
UNIT=$(new_simulator iPhone-18-Pro "HS CI Perf Unit")
rm -rf $RESULTS/perf-unit.xcresult
SIM=$UNIT DD=$PERF_DD XCTESTRUN=$PERF_RUN test_without_building $RESULTS/perf-unit.xcresult -only-testing:HomespunTests/PerformanceTests 2>&1 \
  | tee $RESULTS/perf-unit.log | grep -E "LibraryState of|GridData |ledger|library snapshot|✘|Test run with|recorded an issue"
(( ${pipestatus[1]} == 0 )) || failed+=unit
remove_simulator $UNIT
echo "::endgroup::"
for pose in close open; do
    echo "::group::UI budgets ($pose)"
    xcrun simctl bootstatus $PERF_SIM -b >/dev/null 2>&1
    $DUOCTL -d $PERF_SIM $pose >/dev/null 2>&1; sleep 30
    xcrun simctl privacy $PERF_SIM grant photos photos.homespun.app
    rm -rf $RESULTS/perf-ui-$pose.xcresult
    # On the open Duo XCTest's gestures don't reach the app: only what the app drives itself counts there.
    TESTS=(-only-testing:HomespunUITests/PerformanceUITests)
    [[ $pose == open ]] && TESTS=(-only-testing:HomespunUITests/PerformanceUITests/test01LaunchToGrid
      -only-testing:HomespunUITests/PerformanceUITests/test06SwitchTabs -only-testing:HomespunUITests/PerformanceUITests/test10AutoscrollTheLibrary)
    TEST_RUNNER_HOMESPUN_PERF=1 SIM=$PERF_SIM DD=$PERF_DD XCTESTRUN=$PERF_RUN \
      test_without_building $RESULTS/perf-ui-$pose.xcresult $TESTS 2>&1 \
      | tee $RESULTS/perf-ui-$pose.log | filter
    (( ${pipestatus[1]} == 0 )) || failed+=ui-$pose
    grep -Eq 'Needs perf.sh|Run with ci/perf.sh' $RESULTS/perf-ui-$pose.log && failed+=environment-$pose
    echo "::endgroup::"
done
echo "::group::launch"
$DUOCTL -d $PERF_SIM close >/dev/null 2>&1; sleep 5
values=()
for run in 1 2 3 4 5; do
    xcrun simctl terminate $PERF_SIM photos.homespun.app 2>/dev/null; sleep 2
    rm -f "$(xcrun simctl get_app_container $PERF_SIM photos.homespun.app data)/Documents/perf-monitor.txt"
    xcrun simctl launch $PERF_SIM photos.homespun.app -onboardingComplete YES -hideTips YES -session.foreground NO -perfMonitor YES >/dev/null
    sleep 10
    main=$(tr ";" "\n" < "$(xcrun simctl get_app_container $PERF_SIM photos.homespun.app data)/Documents/perf-monitor.txt" \
      | grep "^launchFromMain=" | cut -d= -f2)
    echo "PERF launch $run: $main ms from the app's code"
    values+=${main:-99999}
done
median=$(printf "%s\n" $values | sort -n | sed -n 3p)
echo "PERF launch median from the app's code: $median ms (budget 1200)" | tee $RESULTS/perf-launch.log
(( ${median%.*} < 1200 )) || failed+=launch
xcrun simctl terminate $PERF_SIM photos.homespun.app 2>/dev/null
echo "::endgroup::"
(( ${#failed} == 0 )) || { echo "failed: ${failed[*]}"; exit 1; }
