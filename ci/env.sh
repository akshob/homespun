# Sourced by the CI scripts (GitHub's macOS machines, or any Mac): paths and tools.
# SPDX-License-Identifier: Apache-2.0
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
zmodload zsh/datetime

# Stamps go to stderr: command substitutions (notably the simulator UDID) stay unchanged.
stamp() {
    [[ -n ${NAME:-} ]] || return 0
    local now=${2:-$EPOCHSECONDS} utc
    TZ=UTC strftime -s utc '%H:%M:%S' $now
    print -u2 -r -- "⏱ $utc $NAME $1"
    printf '%s\t%s\t%s\n' "$NAME" "$1" "$now" >> $RESULTS/$NAME-timing.tsv
}

timed() {
    local phase=$1 code=0; shift
    stamp $phase.start
    "$@" || code=$?
    stamp $phase.end
    return $code
}

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

# On a shared Mac, SIM_SLOTS_DIR (a folder every account can write) limits how many simulators run at
# once (SIM_SLOTS, default 2): a script takes a slot before it boots a simulator, in its own shell
# (not in $(...)), and holds it until it ends. Unset (GitHub's machines, one job each): no limit.
SIM_SLOTS=${SIM_SLOTS:-2}
take_sim_slot() {
    [[ -n ${SIM_SLOTS_DIR:-} ]] || return 0
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

# On a machine that keeps running after a job (a self-hosted runner, JOB_RECORD=1): what the job
# started (scripts, simulators), so a cancelled job's leftovers can be stopped (GitHub stops only the
# step's own shell). JOB_STATE.pids and .sims list them.
JOB_STATE=$CI_STATE/jobs/${RUNNER_NAME:-local}
if [[ -n ${JOB_RECORD:-} ]]; then
    mkdir -p ${JOB_STATE:h}
    print -r -- "$$ ${(j: :)${=$(ps -o lstart= -p $$)}}" >> $JOB_STATE.pids
fi

# A fresh simulator of a device type; prints its UDID. (KEEP_SIM=1: one that outlives the job.)
new_simulator() {
    local manifest=$CI_STATE/presim/$1 sim="" tries=0
    # The workflow reserves this before spawning presim, so an early consumer cannot boot a second one.
    stamp simulator.presim-wait.start
    while [[ -f $manifest.pending ]]; do
        if (( tries++ >= ${PRESIM_TIMEOUT:-180} )); then
            stamp simulator.presim-wait.end
            echo "background simulator creation timed out for $1" >&2
            return 1
        fi
        sleep 1
    done
    stamp simulator.presim-wait.end
    if [[ -f $manifest ]] && mv $manifest $manifest.claim-$$ 2>/dev/null; then
        sim=$(<$manifest.claim-$$)
        rm -f $manifest.claim-$$
        timed simulator.rename xcrun simctl rename $sim "$2" >&2 || { remove_simulator $sim; return 1; }
    else
        stamp simulator.create.start
        sim=$(xcrun simctl create "$2" com.apple.CoreSimulator.SimDeviceType.$1 $(runtime_for $1)) || return 1
        stamp simulator.create.end
        timed simulator.boot xcrun simctl boot $sim >&2 || { remove_simulator $sim; return 1; }
    fi
    [[ -n ${JOB_RECORD:-} && -z ${KEEP_SIM:-} ]] && print -r -- $sim >> $JOB_STATE.sims
    timed simulator.bootstatus xcrun simctl bootstatus $sim -b >/dev/null || { remove_simulator $sim; return 1; }
    echo $sim
}

# An archived .xctestrun is relocatable with Build/Products and never resolves the package graph.
test_without_building() {
    local result=$1; shift
    local specs=($DD/Build/Products/Homespun_*iphonesimulator*.xctestrun(N))
    local spec=${XCTESTRUN:-${specs[1]:-}}
    if [[ -f $spec ]]; then
        xcodebuild test-without-building -xctestrun "$spec" -destination id=$SIM \
          -resultBundlePath "$result" "$@"
    elif [[ ${GITHUB_ACTIONS:-} == true ]]; then
        echo "error: the build artifact has no Homespun simulator .xctestrun" >&2
        return 1
    else
        (cd $APP && xcodebuild test-without-building -project Homespun.xcodeproj -scheme Homespun \
          -destination id=$SIM -derivedDataPath $DD -resultBundlePath "$result" "$@")
    fi
}

# Missing TEST_RUNNER_* variables must not turn a server flow into a green, skipped suite.
require_test_environment() {
    if grep -Eq 'Set HOMESPUN_SERVER|Needs a server\.|Run with ci/(later\.sh|lane\.sh telemetry)|Run on (the open iPhone Duo|the iPhone Duo with)' "$1"; then
        echo "error: server or runner variables did not reach the tests (see $1)" >&2
        return 1
    fi
}

# Waits until nothing answers on this port (a server from an earlier try may still be stopping).
wait_port_free() {
    local tries=0
    while curl -fs -o /dev/null --max-time 2 http://127.0.0.1:$1/api/v1/health; do
        (( ++tries > 30 )) && { echo "port $1 is still in use"; return 1; }
        sleep 1
    done
}

# Tests listed in quarantine.txt (known failures, each with its issue) that fall within these
# -only-testing ids: prints -skip-testing arguments, and writes them to $2 for the summary.
quarantined() {
    local only=(${(s:,:)1}) line id
    : > $2
    while read -r id issue; do
        [[ -z $id || $id == \#* ]] && continue
        for line in $only; do
            if [[ $id == $line || $id == $line/* ]]; then
                print -r -- "$id $issue" >> $2
                print -r -- "-skip-testing:$id"
            fi
        done
    done < $ROOT/ci/quarantine.txt
}

# Xcode's own retry: a failing test runs once more in place (RETRY_UI=1), so a flaky query or a slow
# machine doesn't fail the run, and a real failure still does.
test_retries() { [[ -n ${RETRY_UI:-} ]] && print -r -- "-retry-tests-on-failure -test-iterations 2"; }

# Waits until the temporary server on this port answers.
wait_for_server() {
    local tries=0
    until curl -fs -o /dev/null http://127.0.0.1:$1/api/v1/health; do
        (( ++tries > 90 )) && { echo "the test server on port $1 didn't start"; return 1; }
        sleep 1
    done
}

# `homespun-server pair` for a code that lasts 3 hours (a run can spend longer than 10 minutes
# before its first test pairs); tries again if the catalog is busy. Prints its output.
pairing_output() {
    local out tries=0
    while (( tries++ < 6 )); do
        out=$($SERVER_BIN pair --minutes 180 2>&1)
        [[ $out == *"Pairing code: "* ]] && { print -r -- $out; return 0; }
        print -r -- "pair didn't give a code: $out" >&2
        sleep 5
    done
    return 1
}

remove_simulator() { xcrun simctl shutdown $1 2>/dev/null; xcrun simctl delete $1 2>/dev/null; true; }

# Lines of xcodebuild's output worth keeping in the log.
filter() {
    grep --line-buffered -E "error:|warning: .*Homespun|Test Case.*(started|passed|failed|skipped)|Test run started|TEST (SUCC|FAIL)|BUILD (SUCC|FAIL)|PERF |✘|✔ Test run|recorded an issue" \
      | grep --line-buffered -v appintents | {
        local line first="" last=""
        while IFS= read -r line; do
            if [[ $line == *"Test Case"*"started"* || $line == *"Test run started"* ]]; then
                if [[ -z $first ]]; then
                    stamp xcodebuild.first-test
                    first=1
                fi
            fi
            if [[ $line == *"Test Case"*("passed"|"failed"|"skipped")* || $line == *"✔ Test run"* ]]; then
                last=$EPOCHSECONDS
            fi
            print -r -- "$line"
        done
        [[ -z $last ]] || stamp xcodebuild.last-test $last
      }
    true
}
