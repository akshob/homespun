#!/bin/zsh
# The watch's scrolling regression: no server, paired iPhone or Photos library.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source ${0:A:h}/env.sh
NAME=watch
stamp segment.start
timed simulator.slot take_sim_slot
DEVICE=Apple-Watch-Series-12-46mm
if [[ -z $(runtime_for $DEVICE) ]]; then
    echo "Installing the watchOS simulator runtime"
    timed runtime.download xcodebuild -downloadPlatform watchOS
fi
[[ -n $(runtime_for $DEVICE) ]] || { echo "error: No watchOS simulator runtime for $DEVICE"; exit 1; }
# The iPhone build embeds the watch app, but doesn't build its watchOS UI test bundle.
WATCH_DD=$DD/watch
cd $APP
timed build.generate zsh scripts/generate-project.sh --testing
stamp build.start
STATUS=0
xcodebuild build-for-testing -project Homespun.xcodeproj -scheme HomespunWatch \
  -destination 'generic/platform=watchOS Simulator' -derivedDataPath $WATCH_DD \
  -clonedSourcePackagesDirPath $CI_STATE/spm 2>&1 \
  | tee $RESULTS/watch-build.log | filter || STATUS=$?
stamp build.end
(( STATUS == 0 )) || { stamp segment.end; exit $STATUS; }
SIM=$(new_simulator $DEVICE "HS CI Watch $SHA") || exit 1
trap 'stamp cleanup.start; remove_simulator $SIM; stamp cleanup.end; stamp segment.end' EXIT
rm -rf $RESULTS/watch.xcresult
WATCH_SPECS=($WATCH_DD/Build/Products/HomespunWatch_*watchsimulator*.xctestrun(N))
(( ${#WATCH_SPECS} )) || { echo "error: watch build produced no .xctestrun"; exit 1; }
stamp xcodebuild.start
XCTESTRUN=$WATCH_SPECS[1] test_without_building $RESULTS/watch.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 240 \
  $(test_retries) 2>&1 | tee $RESULTS/watch.log | filter || STATUS=$?
stamp xcodebuild.end
exit $STATUS
