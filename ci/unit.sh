#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# The app's unit tests (and the PhotoKit ones, hosted in the app) and the widgets' (every size drawn)
# on a fresh iPhone simulator with Photos access. Performance budgets run in perf.sh (Profile build).
set -uo pipefail
source ${0:A:h}/env.sh
NAME=unit
stamp segment.start
timed simulator.slot take_sim_slot
SIM=$(new_simulator iPhone-18-Pro "HS CI Unit $SHA")
trap 'stamp cleanup.start; remove_simulator $SIM; stamp cleanup.end; stamp segment.end' EXIT
timed simulator.privacy xcrun simctl privacy $SIM grant photos photos.homespun.app.dev
cd $APP
rm -rf $RESULTS/unit.xcresult
stamp xcodebuild.start
xcodebuild test-without-building -project Homespun.xcodeproj -scheme Homespun -destination id=$SIM -derivedDataPath $DD \
  -resultBundlePath $RESULTS/unit.xcresult -only-testing:HomespunTests -only-testing:HomespunWidgetTests \
  -skip-testing:HomespunTests/PerformanceTests 2>&1 \
  | tee $RESULTS/unit.log | filter
STATUS=$?
stamp xcodebuild.end
exit $STATUS
