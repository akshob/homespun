#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "${0:A:h}/.."
enabled=$(sed -n 's/^HOMESPUN_RELEASE_FEATURES = //p' ReleaseFeatures.xcconfig)
[[ $enabled == YES || $enabled == NO ]] || { echo "Invalid release-features switch" >&2; exit 1; }
spec=project.yml
if [[ $enabled == YES || ${1:-} == --testing ]]; then spec=project-features.yml; fi
xcodegen generate --quiet --spec "$spec"
