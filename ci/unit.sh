#!/bin/zsh
# The app's unit tests (and the PhotoKit ones, hosted in the app) and the widgets' (every size drawn)
# on a fresh iPhone simulator with Photos access. Performance budgets run in perf.sh (Profile build).
set -uo pipefail
source ${0:A:h}/env.sh
take_sim_slot
SIM=$(new_simulator iPhone-18-Pro "HS CI Unit $SHA")
trap "remove_simulator $SIM" EXIT
xcrun simctl privacy $SIM grant photos photos.homespun.app.dev
cd $APP
rm -rf $RESULTS/unit.xcresult
xcodebuild test-without-building -project Homespun.xcodeproj -scheme Homespun -destination id=$SIM -derivedDataPath $DD \
  -resultBundlePath $RESULTS/unit.xcresult -only-testing:HomespunTests -only-testing:HomespunWidgetTests \
  -skip-testing:HomespunTests/PerformanceTests 2>&1 \
  | tee $RESULTS/unit.log | filter
