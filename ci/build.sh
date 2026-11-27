#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# Builds what the tests need, once per commit: the release server (the UI tests' temporary
# servers) and the app with its tests (Debug, for any simulator). Later jobs of the run reuse it.
set -euo pipefail
source ${0:A:h}/env.sh
cd $ROOT
# Only build jobs need the generated project; test jobs use the archived .xctestrun.
(cd $APP && zsh scripts/generate-project.sh --testing)
# A branch's push and its pull request build the same commit at once: one builds, the other waits.
mkdir -p $CI_STATE/dd
zmodload zsh/system
: >> $CI_STATE/dd/$SHA.lock
zsystem flock -f lockfd $CI_STATE/dd/$SHA.lock    # held until this script ends
OLD_COMMIT=b35fc1901551ea1b01807a26f6a73cbbf68d8058
if [[ ${LANES:-} == *oldserver* || ${LANES:-} == *oldapp-upgrade* ]]; then
    fixture=$CI_STATE/fixtures/server-b35fc19
    mkdir -p $fixture
    if [[ ! -x $fixture/homespun-server ]]; then
        source=$CI_STATE/server-b35fc19
        git worktree add --detach $source $OLD_COMMIT
        (
            trap 'git -C $ROOT worktree remove --force $source' EXIT
            cd $source
            swift build -c release --product homespun-server 2>&1 | tail -3
            cp .build/release/homespun-server $fixture/homespun-server
        )
    fi
    mkdir -p $DD
    cp $fixture/homespun-server $OLD_SERVER_BIN
fi
check_old_app() {
    local products=$1 plist=$1/Debug-iphonesimulator/Homespun.app/Info.plist key expected actual
    local specs=($products/Homespun_*iphonesimulator*.xctestrun(N))
    [[ -f $plist && -d $products/Debug-iphonesimulator/HomespunUITests-Runner.app && ${#specs} == 1 ]] \
      || { echo "error: incomplete 1.0 app fixture (b35fc19): $products" >&2; return 1; }
    for key expected in CFBundleIdentifier photos.homespun.app.dev CFBundleShortVersionString 1.0.0 \
                        CFBundleVersion 1 HomespunReleaseFeatures NO; do
        actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist") || return 1
        [[ $actual == $expected ]] \
          || { echo "error: 1.0 fixture $key is $actual, expected $expected" >&2; return 1; }
    done
    echo "verified 1.0 app: photos.homespun.app.dev, version 1.0.0 (1), release features NO"
}
if [[ ${LANES:-} == *oldapp* ]]; then
    fixture=$CI_STATE/fixtures/app-b35fc19
    if [[ ! -f $fixture/.built ]]; then
        rm -rf $fixture $fixture.partial
        source=$CI_STATE/app-b35fc19-src dd=$CI_STATE/app-b35fc19-dd
        [[ ! -d $source ]] || git worktree remove --force $source
        rm -rf $dd
        git worktree add --detach $source $OLD_COMMIT
        (
            trap 'git -C $ROOT worktree remove --force $source; rm -rf $dd' EXIT
            [[ $(git -C $source rev-parse HEAD) == $OLD_COMMIT ]]
            cd $source/Apps/Homespun
            : > $RESULTS/oldapp-build.log
            build_old_app() {
                zsh scripts/generate-project.sh --testing || return 1
                # Resolve the immutable source's graph, even though XcodeGen has no workspace lockfile.
                local resolved=Homespun.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
                mkdir -p $resolved && cp $source/Package.resolved $resolved/Package.resolved || return 1
                xcodebuild build-for-testing -project Homespun.xcodeproj -scheme Homespun \
                  -destination "generic/platform=iOS Simulator" -derivedDataPath $dd \
                  -clonedSourcePackagesDirPath $CI_STATE/spm 2>&1 | tee -a $RESULTS/oldapp-build.log | filter
            }
            if ! build_old_app; then
                echo "retrying the 1.0 fixture with its original XcodeGen 2.46.0"
                tools=$CI_STATE/tools/xcodegen-2.46.0
                mkdir -p $tools
                if [[ ! -x $tools/xcodegen/bin/xcodegen ]]; then
                    curl -fL --retry 3 -o $tools/xcodegen.zip \
                      https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
                    print -r -- "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806  $tools/xcodegen.zip" \
                      | shasum -a 256 -c -
                    ditto -xk $tools/xcodegen.zip $tools
                fi
                export PATH=$tools/xcodegen/bin:$PATH
                rm -rf $dd
                build_old_app
            fi
            mkdir -p $fixture.partial/Build
            ditto $dd/Build/Products $fixture.partial/Build/Products
            print -r -- "commit $OLD_COMMIT
xcodegen $(xcodegen --version)
$(xcodebuild -version | tr '\n' ' ')" > $fixture.partial/BUILD-INFO
        )
        check_old_app $fixture.partial/Build/Products
        touch $fixture.partial/.built
        mv $fixture.partial $fixture
    fi
    [[ $(head -1 $fixture/BUILD-INFO) == "commit $OLD_COMMIT" ]] \
      || { echo "error: wrong commit in the 1.0 app fixture" >&2; exit 1; }
    check_old_app $fixture/Build/Products
    cat $fixture/BUILD-INFO
    du -sh $fixture
    mkdir -p $DD/app-b35fc19
    ditto $fixture/Build $DD/app-b35fc19/Build
    cp $fixture/BUILD-INFO $DD/app-b35fc19/BUILD-INFO
fi
archive_build() {
    [[ -n ${BUILD_ARCHIVE:-} ]] || return 0
    local extra=()
    [[ ${LANES:-} == *oldserver* || ${LANES:-} == *oldapp-upgrade* ]] && extra+=($SHA/homespun-server-b35fc19)
    [[ ${LANES:-} == *oldapp* ]] && extra+=($SHA/app-b35fc19)
    tar -czf $BUILD_ARCHIVE -C $CI_STATE/dd $SHA/Build/Products $SHA/homespun-server $SHA/.built $extra
    ls -lh $BUILD_ARCHIVE
}
if [[ -f $DD/.built && -x $SERVER_BIN ]]; then
    echo "already built for $SHA"
    archive_build
    exit 0
fi
xcrun swiftc -parse-as-library -typecheck Apps/Homespun/Homespun/Features/Demo/DemoArt.swift \
  Apps/Homespun/scripts/demo-media.swift
swift build -c release --product homespun-server 2>&1 | tail -3
cd $APP
set -o pipefail
xcodebuild build-for-testing -project Homespun.xcodeproj -scheme Homespun -destination "generic/platform=iOS Simulator" \
  -derivedDataPath $DD -clonedSourcePackagesDirPath $CI_STATE/spm 2>&1 | tee $RESULTS/build.log | filter
xcodebuild build-for-testing -project Homespun.xcodeproj -scheme HomespunReleaseScope \
  -destination "generic/platform=iOS Simulator" -derivedDataPath $DD \
  -clonedSourcePackagesDirPath $CI_STATE/spm 2>&1 | tee $RESULTS/release-scope-build.log | filter
cp $ROOT/.build/release/homespun-server $SERVER_BIN
touch $DD/.built
# For a run's other jobs on other machines: the built app, its tests and the server in one archive
# (permissions kept), unpacked into ~/ci/dd by `tar -xzf <archive> -C ~/ci/dd`.
archive_build
# Old commits' builds go (the newest few stay for re-runs).
ls -1dt $CI_STATE/dd/*(N/) | tail -n +6 | while read old; do rm -rf $old $old.lock; done
