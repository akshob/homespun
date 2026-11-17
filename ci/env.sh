# Sourced by the CI scripts (polonium's `homespun-ci` account, or anyone's Mac): paths and tools.
#   ROOT      the checkout
#   CI_STATE  what lasts between runs: built products, the duoctl cache, the perf simulator (~/ci)
#   DD        Xcode's derived data for this commit (shared by the jobs of one run)
#   RESULTS   result bundles, logs and screenshots for the workflow to upload
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
ROOT=${ROOT:-${0:A:h:h}}
CI_STATE=${CI_STATE:-$HOME/ci}
SHA=${GITHUB_SHA:-$(git -C $ROOT rev-parse HEAD 2>/dev/null || echo local)}
# A pull request is tested at its head commit (not GitHub's merge commit), like its pushes.
[[ -n ${HEAD_SHA:-} ]] && SHA=$HEAD_SHA
DD=${DD:-$CI_STATE/dd/$SHA}
RESULTS=${RESULTS:-$ROOT/ci-results}
SEED=${SEED:-$ROOT/ci/seed}
SERVER_BIN=${SERVER_BIN:-$ROOT/.build/release/homespun-server}
# iPhone Duo's fold and rotate tool (from the design tools; copied into CI_STATE when the runner is set up).
DUOCTL=${DUOCTL:-$CI_STATE/tools/duoctl/duoctl}
[[ -x $DUOCTL ]] || DUOCTL=$HOME/homespun-design/duo/tools/duoctl/duoctl
export XDG_CACHE_HOME=${XDG_CACHE_HOME:-$CI_STATE/duo-cache}
APP=$ROOT/Apps/Homespun
RUNTIME_IPHONE=com.apple.CoreSimulator.SimRuntime.iOS-27-2
RUNTIME_DUO=com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4
mkdir -p $CI_STATE $RESULTS

runtime_for() { [[ $1 == iPhone-Duo ]] && echo $RUNTIME_DUO || echo $RUNTIME_IPHONE; }

# A fresh simulator of a device type; prints its UDID.
new_simulator() {
    local sim=$(xcrun simctl create "$2" com.apple.CoreSimulator.SimDeviceType.$1 $(runtime_for $1))
    xcrun simctl boot $sim && xcrun simctl bootstatus $sim -b >/dev/null
    echo $sim
}

remove_simulator() { xcrun simctl shutdown $1 2>/dev/null; xcrun simctl delete $1 2>/dev/null; true; }

# Lines of xcodebuild's output worth keeping in the log.
filter() { grep -E "error:|warning: .*Homespun|Test Case.*(passed|failed|skipped)|TEST (SUCC|FAIL)|BUILD (SUCC|FAIL)|PERF |✘|✔ Test run|recorded an issue" | grep -v appintents; true; }
