#!/bin/zsh
# Installs a GitHub Actions runner in the current account (`homespun-ci` on polonium) for the private
# performance repository and starts it as a launch agent.
#   ci/install-runner.sh <name> <registration token>
# The token comes from `gh api -X POST repos/akshob/homespun-perf/actions/runners/registration-token`
# (valid for an hour). REPO=owner/name registers it elsewhere.
set -euo pipefail
name=$1 token=$2
repo=https://github.com/${REPO:-akshob/homespun-perf}
dir=$HOME/actions-runner/$name

mkdir -p $dir && cd $dir
if [[ ! -x ./config.sh ]]; then
    version=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')
    curl -fsSL https://github.com/actions/runner/releases/download/v$version/actions-runner-osx-arm64-$version.tar.gz | tar xz
fi
./config.sh --unattended --replace --url $repo --token $token --name $name --labels homespun-ci --work _work
# The launch agent doesn't read a login shell's PATH: Homebrew (xcodegen, ffmpeg, axe) first.
print /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin > .path
./svc.sh install >/dev/null
# Simulators need the account's desktop session: the launch agent starts with it (log in once on the
# Mac's screen, then switch users without logging out).
if launchctl print gui/$(id -u) >/dev/null 2>&1; then
    ./svc.sh start
    ./svc.sh status | tail -3
else
    echo "$name is installed; it starts when $(id -un) logs in on the Mac's screen."
fi
