#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# The app's unit tests (and the PhotoKit ones, hosted in the app) and the widgets' (every size drawn)
# on a fresh iPhone simulator with Photos access. Performance budgets run in perf.sh (Profile build).
set -uo pipefail
source ${0:A:h}/env.sh
NAME=unit
stamp segment.start
timed simulator.slot take_sim_slot
SIM=$(new_simulator iPhone-18-Pro "HS CI Unit $SHA") || exit 1
trap 'stamp cleanup.start; remove_simulator $SIM; stamp cleanup.end; stamp segment.end' EXIT
timed simulator.privacy xcrun simctl privacy $SIM grant photos photos.homespun.app.dev
rm -rf $RESULTS/unit.xcresult
stamp xcodebuild.start
test_without_building $RESULTS/unit.xcresult -only-testing:HomespunTests -only-testing:HomespunWidgetTests \
  -skip-testing:HomespunTests/PerformanceTests 2>&1 \
  | tee $RESULTS/unit.log | filter
STATUS=$?
stamp xcodebuild.end
if (( STATUS == 0 )); then
    specs=($DD/Build/Products/HomespunReleaseScope_*iphonesimulator*.xctestrun(N))
    if (( ${#specs} != 1 )); then
        echo "error: missing release-scope test manifest" >&2
        exit 1
    fi
    rm -rf $RESULTS/release-scope.xcresult
    stamp xcodebuild.start
    XCTESTRUN=$specs[1] test_without_building $RESULTS/release-scope.xcresult 2>&1 \
      | tee $RESULTS/release-scope.log | filter
    STATUS=$?
    stamp xcodebuild.end
    if ! grep -Eq 'testReleaseDisablesEntryPoints.*passed' $RESULTS/release-scope.log; then
        echo "error: release-scope regression did not execute and pass" >&2
        STATUS=1
    fi
fi
exit $STATUS
