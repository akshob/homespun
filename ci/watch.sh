#!/bin/zsh
# The watch's scrolling regression: no server, paired iPhone or Photos library.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source ${0:A:h}/env.sh
take_sim_slot
DEVICE=Apple-Watch-Series-12-46mm
if [[ -z $(runtime_for $DEVICE) ]]; then
    echo "Installing the watchOS simulator runtime"
    xcodebuild -downloadPlatform watchOS
fi
[[ -n $(runtime_for $DEVICE) ]] || { echo "error: No watchOS simulator runtime for $DEVICE"; exit 1; }
# The iPhone build embeds the watch app, but doesn't build its watchOS UI test bundle.
WATCH_DD=$DD/watch
cd $APP
xcodegen generate --quiet
xcodebuild build-for-testing -project Homespun.xcodeproj -scheme HomespunWatch \
  -destination 'generic/platform=watchOS Simulator' -derivedDataPath $WATCH_DD 2>&1 \
  | tee $RESULTS/watch-build.log | filter
SIM=$(new_simulator $DEVICE "HS CI Watch $SHA")
trap "remove_simulator $SIM" EXIT
rm -rf $RESULTS/watch.xcresult
xcodebuild test-without-building -project Homespun.xcodeproj -scheme HomespunWatch \
  -destination id=$SIM -derivedDataPath $WATCH_DD -resultBundlePath $RESULTS/watch.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 240 \
  $(test_retries) 2>&1 | tee $RESULTS/watch.log | filter
