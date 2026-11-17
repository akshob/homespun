# Sourced by the CI scripts (polonium's `homespun-ci` account, or anyone's Mac): paths and tools.
#   ROOT      the checkout
#   CI_STATE  what lasts between runs: built products, the duoctl cache, the perf simulator (~/ci)
#   DD        Xcode's derived data for this commit (shared by the jobs of one run)
#   RESULTS   result bundles, logs and screenshots for the workflow to upload
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# GitHub's xcode-27 image starts with Xcode 27.1; the app needs 27.2 (the iOS 27.2 SDK).
[[ -z ${DEVELOPER_DIR:-} && -d /Applications/Xcode_27.2.app ]] && export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
ROOT=${ROOT:-${0:A:h:h}}
CI_STATE=${CI_STATE:-$HOME/ci}
SHA=${GITHUB_SHA:-$(git -C $ROOT rev-parse HEAD 2>/dev/null || echo local)}
# A pull request is tested at its head commit (not GitHub's merge commit), like its pushes.
[[ -n ${HEAD_SHA:-} ]] && SHA=$HEAD_SHA
DD=${DD:-$CI_STATE/dd/$SHA}
RESULTS=${RESULTS:-$ROOT/ci-results}
SEED=${SEED:-$ROOT/ci/seed}
# The release server the UI tests run, kept with the build (build.sh) so other machines get it too.
SERVER_BIN=${SERVER_BIN:-$DD/homespun-server}
# iPhone Duo's fold, rotate and screenshot tool.
DUOCTL=${DUOCTL:-$ROOT/ci/tools/duoctl/duoctl}
export XDG_CACHE_HOME=${XDG_CACHE_HOME:-$CI_STATE/duo-cache}
APP=$ROOT/Apps/Homespun
mkdir -p $CI_STATE $RESULTS

# The newest installed simulator runtime for a device type (iPhone Duo has a runtime of its own).
runtime_for() {
    xcrun simctl list runtimes -j | python3 -c '
import json, sys
kind = "com.apple.CoreSimulator.SimDeviceType." + sys.argv[1]
fits = [r for r in json.load(sys.stdin)["runtimes"]
        if r.get("isAvailable") and any(d["identifier"] == kind for d in r.get("supportedDeviceTypes", []))]
fits.sort(key=lambda r: [int(part) for part in r["version"].split(".")])
print(fits[-1]["identifier"] if fits else "")' $1
}

# polonium has 16 GB: past two simulators at once (CI's lanes, anyone's tests) it swaps and tests
# time out. A script takes one of the machine's simulator slots (shared by every account) before it
# boots a simulator, in its own shell (not in $(...)), and holds it until it ends.
SIM_SLOTS=${SIM_SLOTS:-2}
SIM_SLOTS_DIR=${SIM_SLOTS_DIR:-/Users/Shared/homespun-sim-slots}
take_sim_slot() {
    zmodload zsh/system
    [[ -d $SIM_SLOTS_DIR ]] || { mkdir -p $SIM_SLOTS_DIR && chmod 1777 $SIM_SLOTS_DIR; }
    local waited=0 slot file
    typeset -g SIM_SLOT_FD
    while true; do
        for slot in {1..$SIM_SLOTS}; do
            file=$SIM_SLOTS_DIR/slot-$slot
            [[ -e $file ]] || { : >> $file && chmod 666 $file; } 2>/dev/null
            if zsystem flock -t 0 -f SIM_SLOT_FD $file 2>/dev/null; then
                (( waited == 0 )) || echo "simulator slot $slot after waiting ${waited}s"
                return 0
            fi
        done
        sleep 15; (( waited += 15 ))
    done
}

# What this runner's job started (scripts, simulators), so ci/reset.sh can stop it when a job is
# cancelled: GitHub stops only the step's own shell, and the scripts under it kept going for hours.
JOB_STATE=$CI_STATE/jobs/${RUNNER_NAME:-}
if [[ -n ${RUNNER_NAME:-} ]]; then
    mkdir -p ${JOB_STATE:h}
    print -r -- "$$ ${(j: :)${=$(ps -o lstart= -p $$)}}" >> $JOB_STATE.pids
fi

# A fresh simulator of a device type; prints its UDID. (KEEP_SIM=1: one that outlives the job.)
new_simulator() {
    local sim=$(xcrun simctl create "$2" com.apple.CoreSimulator.SimDeviceType.$1 $(runtime_for $1))
    [[ -n ${RUNNER_NAME:-} && -z ${KEEP_SIM:-} ]] && print -r -- $sim >> $JOB_STATE.sims
    xcrun simctl boot $sim && xcrun simctl bootstatus $sim -b >/dev/null
    echo $sim
}

remove_simulator() { xcrun simctl shutdown $1 2>/dev/null; xcrun simctl delete $1 2>/dev/null; true; }

# Lines of xcodebuild's output worth keeping in the log.
filter() { grep -E "error:|warning: .*Homespun|Test Case.*(passed|failed|skipped)|TEST (SUCC|FAIL)|BUILD (SUCC|FAIL)|PERF |✘|✔ Test run|recorded an issue" | grep -v appintents; true; }
