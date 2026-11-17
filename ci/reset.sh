#!/bin/zsh
# Stops what this runner's earlier job left running and deletes its simulators. A cancelled job's
# scripts keep going (GitHub stops only the step's shell), holding simulators and memory. Every
# Apple job runs this first and last (also when cancelled). A process is stopped only if it is the
# one recorded (same start time), so a reused process ID is never touched.
set -u
[[ -n ${RUNNER_NAME:-} ]] || exit 0
STATE=${CI_STATE:-$HOME/ci}/jobs/$RUNNER_NAME
tree() { local child; for child in $(pgrep -P $1); do tree $child; done; print $1; }
if [[ -f $STATE.pids ]]; then
    stale=()
    while read -r pid started; do
        [[ -n $pid && "${(j: :)${=$(ps -o lstart= -p $pid 2>/dev/null)}}" == "$started" ]] && stale+=($(tree $pid))
    done < $STATE.pids
    if (( ${#stale} )); then
        echo "stopping what an earlier job left running: ${stale[*]}"
        kill ${stale[@]} 2>/dev/null; sleep 5; kill -9 ${stale[@]} 2>/dev/null
    fi
    rm -f $STATE.pids
fi
if [[ -f $STATE.sims ]]; then
    for sim in $(cat $STATE.sims); do
        xcrun simctl shutdown $sim 2>/dev/null; xcrun simctl delete $sim 2>/dev/null
    done
    rm -f $STATE.sims
fi
true
