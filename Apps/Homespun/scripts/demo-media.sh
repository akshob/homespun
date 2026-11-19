#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
D=${0:A:h}
ROOT=${D:h:h:h}
mkdir -p "$ROOT/.build"
xcrun swiftc -parse-as-library -O "$ROOT/Apps/Homespun/Homespun/Features/Demo/DemoArt.swift" \
    "$D/demo-media.swift" -o "$ROOT/.build/demo-media"
"$ROOT/.build/demo-media" "${1:-$ROOT/Apps/Homespun/Homespun/Resources/Demo}"
