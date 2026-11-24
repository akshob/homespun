#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "${0:A:h}/.."
enabled=$(sed -n 's/^HOMESPUN_RELEASE_FEATURES = //p' ReleaseFeatures.xcconfig)
[[ $enabled == YES || $enabled == NO ]] || { echo "Invalid release-features switch" >&2; exit 1; }
spec=project.yml
if [[ $enabled == YES || ${1:-} == --testing ]]; then spec=project-features.yml; fi
if [[ -n ${HOMESPUN_WAKE_RELAY_URL:-} ]]; then
    [[ $enabled == YES || ${1:-} == --testing ]] || { echo "Wake enrollment requires the current feature scope" >&2; exit 1; }
    [[ $HOMESPUN_WAKE_RELAY_URL =~ '^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?(/[A-Za-z0-9._~%/-]*)?$' ]] \
        || { echo "Wake relay must be an HTTPS origin without credentials, query or fragment" >&2; exit 1; }
    spec=project-wake.yml
fi
xcodegen generate --quiet --spec "$spec"
