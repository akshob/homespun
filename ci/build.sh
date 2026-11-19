#!/bin/zsh
# Builds what the tests need, once per commit: the release server (the UI tests' temporary
# servers) and the app with its tests (Debug, for any simulator). Later jobs of the run reuse it.
set -euo pipefail
source ${0:A:h}/env.sh
cd $ROOT
# Every job's checkout needs the project (it isn't committed), also when it reuses a build.
(cd $APP && xcodegen generate --quiet)
# A branch's push and its pull request build the same commit at once: one builds, the other waits.
mkdir -p $CI_STATE/dd
zmodload zsh/system
: >> $CI_STATE/dd/$SHA.lock
zsystem flock -f lockfd $CI_STATE/dd/$SHA.lock    # held until this script ends
if [[ -f $DD/.built && -x $SERVER_BIN ]]; then echo "already built for $SHA"; exit 0; fi
xcrun swiftc -parse-as-library -typecheck Apps/Homespun/Homespun/Features/Demo/DemoArt.swift \
  Apps/Homespun/scripts/demo-media.swift
swift build -c release --product homespun-server 2>&1 | tail -3
cd $APP
set -o pipefail
xcodebuild build-for-testing -project Homespun.xcodeproj -scheme Homespun -destination "generic/platform=iOS Simulator" \
  -derivedDataPath $DD 2>&1 | tee $RESULTS/build.log | filter
cp $ROOT/.build/release/homespun-server $SERVER_BIN
touch $DD/.built
# For a run's other jobs on other machines: the built app, its tests and the server in one archive
# (permissions kept), unpacked into ~/ci/dd by `tar -xzf <archive> -C ~/ci/dd`.
if [[ -n ${BUILD_ARCHIVE:-} ]]; then
    tar -czf $BUILD_ARCHIVE -C $CI_STATE/dd $SHA/Build/Products $SHA/homespun-server $SHA/.built
fi
# Old commits' builds go (the newest few stay for re-runs).
ls -1dt $CI_STATE/dd/*(N/) | tail -n +6 | while read old; do rm -rf $old $old.lock; done
