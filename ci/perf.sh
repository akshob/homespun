#!/bin/zsh
# Performance: unit budgets (Profile build), the UI budgets on the 35,000-photo iPhone Duo simulator
# (setup-perf-sim.sh makes it once), launch time, and a library of 3,000 items opening and paging.
set -u
source ${0:A:h}/env.sh
PERF_DD=$CI_STATE/dd-profile
PERF_SIM=$(cat $CI_STATE/perf-udid 2>/dev/null) || { echo "No performance simulator: run ci/setup-perf-sim.sh once."; exit 1; }
# Its slot ends with the script, so the simulator shuts down too.
trap "xcrun simctl shutdown $PERF_SIM 2>/dev/null" EXIT
failed=()
cd $APP && zsh scripts/generate-project.sh --testing
echo "::group::build (Profile)"
xcodebuild build-for-testing -project Homespun.xcodeproj -scheme HomespunPerf -configuration Profile -destination id=$PERF_SIM \
  -derivedDataPath $PERF_DD 2>&1 | filter
echo "::endgroup::"
take_sim_slot
echo "::group::unit budgets"
UNIT=$(new_simulator iPhone-18-Pro "HS CI Perf Unit")
rm -rf $RESULTS/perf-unit.xcresult
xcodebuild test-without-building -project Homespun.xcodeproj -scheme HomespunPerf -configuration Profile -destination id=$UNIT \
  -derivedDataPath $PERF_DD -resultBundlePath $RESULTS/perf-unit.xcresult -only-testing:HomespunTests/PerformanceTests 2>&1 \
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
    TEST_RUNNER_HOMESPUN_PERF=1 xcodebuild test-without-building -project Homespun.xcodeproj -scheme HomespunPerf -configuration Profile \
      -destination id=$PERF_SIM -derivedDataPath $PERF_DD -resultBundlePath $RESULTS/perf-ui-$pose.xcresult $TESTS 2>&1 \
      | tee $RESULTS/perf-ui-$pose.log | filter
    (( ${pipestatus[1]} == 0 )) || failed+=ui-$pose
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
