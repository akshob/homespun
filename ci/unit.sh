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
TEST_RUNNER_HOMESPUN_SNAPSHOT_DIR=$ROOT/Apps/Homespun/HomespunTests/__Snapshots__ \
TEST_RUNNER_HOMESPUN_SNAPSHOT_RESULTS=$RESULTS/snapshots \
TEST_RUNNER_HOMESPUN_SNAPSHOT_CI=${GITHUB_ACTIONS:-false} \
TEST_RUNNER_HOMESPUN_SNAPSHOT_HOST=iPhone-18-Pro \
TEST_RUNNER_HOMESPUN_XCODE_BUILD=$(xcodebuild -version | awk '/Build version/ {print $3}') \
TEST_RUNNER_HOMESPUN_SNAPSHOTS=${HOMESPUN_SNAPSHOTS:-verify} \
TEST_RUNNER_HOMESPUN_SNAPSHOT_DIAG=${HOMESPUN_SNAPSHOT_DIAG:-1} \
test_without_building $RESULTS/unit.xcresult -only-testing:HomespunTests -only-testing:HomespunWidgetTests \
  -skip-testing:HomespunTests/PerformanceTests 2>&1 \
  | tee $RESULTS/unit.log | filter
STATUS=$?
stamp xcodebuild.end
python3 $ROOT/ci/snapshot_report.py $RESULTS || STATUS=1
exit $STATUS
