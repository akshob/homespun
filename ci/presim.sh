#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# Queue the first simulator's boot while the job installs tools and unpacks the build.
set -euo pipefail
source ${0:A:h}/env.sh
TYPE=$1 NAME=presim
MANIFEST=$CI_STATE/presim/$TYPE
mkdir -p ${MANIFEST:h}
SIM="" PUBLISHED=0
stamp segment.start
cleanup() {
    if (( ! PUBLISHED )) && [[ -n $SIM ]]; then remove_simulator $SIM; fi
    rm -f $MANIFEST.pending $MANIFEST.publish-$$
    stamp segment.end
}
trap cleanup EXIT
[[ -z ${SIM_SLOTS_DIR:-} ]] || { echo "background boot is disabled on simulator-slot hosts"; exit 0; }
[[ ! -f $MANIFEST ]] || { echo "a background simulator is already available for $TYPE"; exit 0; }
touch $MANIFEST.pending
stamp simulator.create.start
SIM=$(xcrun simctl create "HS CI preparing" com.apple.CoreSimulator.SimDeviceType.$TYPE $(runtime_for $TYPE)) || exit $?
stamp simulator.create.end
timed simulator.boot xcrun simctl boot $SIM || exit $?
print -r -- "$SIM" > $MANIFEST.publish-$$
mv $MANIFEST.publish-$$ $MANIFEST
PUBLISHED=1
