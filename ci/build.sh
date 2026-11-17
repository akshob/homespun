#!/bin/zsh
# Builds what the tests need, once per commit: the release server (the UI tests' temporary
# servers) and the app with its tests (Debug, for any simulator). Later jobs of the run reuse it.
set -euo pipefail
source ${0:A:h}/env.sh
cd $ROOT
swift build -c release --product homespun-server 2>&1 | tail -3
if [[ -f $DD/.built ]]; then echo "app already built for $SHA"; exit 0; fi
cd $APP && xcodegen generate --quiet
set -o pipefail
xcodebuild build-for-testing -project Homespun.xcodeproj -scheme Homespun -destination "generic/platform=iOS Simulator" \
  -derivedDataPath $DD 2>&1 | tee $RESULTS/build.log | filter
touch $DD/.built
# Old commits' builds go (the newest few stay for re-runs).
ls -1dt $CI_STATE/dd/*(N/) | tail -n +6 | xargs rm -rf
