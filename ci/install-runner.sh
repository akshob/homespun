#!/bin/zsh
# Installs one GitHub Actions runner instance for this repository in the current account (run as
# `homespun-ci` on polonium, once per instance) and starts it as a launch agent.
#   ci/install-runner.sh <name> <registration token> [duoctl folder]
# The token comes from `gh api -X POST repos/akshob/homespun/actions/runners/registration-token`
# (valid for an hour). The duoctl folder (duoctl + duoctl-helper.m) is copied to ~/ci/tools/duoctl.
set -euo pipefail
name=$1 token=$2 duoctl=${3:-}
repo=https://github.com/akshob/homespun
dir=$HOME/actions-runner/$name

if [[ -n $duoctl ]]; then
    mkdir -p ~/ci/tools/duoctl
    cp $duoctl/duoctl $duoctl/duoctl-helper.m ~/ci/tools/duoctl/
    chmod +x ~/ci/tools/duoctl/duoctl
fi

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
