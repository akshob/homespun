#!/bin/zsh
# UI test runs, each on its own simulator and temporary server; fails if any did. GitHub's machines
# take one run each (the ci workflow's matrix); on one Mac, name several, or a group.
#   lane.sh <run|group> ...
#   runs:   smoke iphone library later copies onboarding telemetry duo-cover duo-open
#   groups: iphone-all (every iPhone run), duo-all (both Duo runs), full (all of them)
# Ports differ, so runs of different jobs can share a Mac.
set -u
D=${0:A:h}
failed=()
run() { local name=$1; shift; echo "::group::$name"; "$@" || failed+=$name; echo "::endgroup::"; }
runs=()
for name in "$@"; do
  case $name in
    iphone-all) runs+=(iphone library later copies onboarding telemetry) ;;
    duo-all) runs+=(duo-cover duo-open) ;;
    full) runs+=(iphone library later copies onboarding telemetry duo-cover duo-open) ;;
    *) runs+=($name) ;;
  esac
done
for one in $runs; do
  case $one in
    smoke)
      run smoke zsh $D/ui.sh smoke iPhone-18-Pro HomespunUITests/LibraryUITests,HomespunUITests/ServerTabUITests/testRenameThisIPhone 8790 ;;
    iphone)
      run iphone zsh $D/ui.sh iphone iPhone-18-Pro \
        HomespunUITests/ItemViewerUITests,HomespunUITests/ServerTabUITests,HomespunUITests/ServerModeUITests,HomespunUITests/PremiumUITests 8794 ;;
    library)
      # A bigger library (the newest cells far from the oldest; the filter crash needed it).
      run library env EXTRA=200 zsh $D/ui.sh library iPhone-18-Pro HomespunUITests/LibraryUITests 8799 ;;
    later)
      run later zsh $D/later.sh later iPhone-18-Pro 8796 ;;
    copies)
      run copies zsh $D/copies.sh copies 8792 ;;
    onboarding)
      # These expect a fresh install of their own.
      run onboarding zsh $D/ui.sh onboarding iPhone-18-Pro HomespunUITests/OnboardingUITests 8797 ;;
    telemetry)
      run telemetry env STUB_PORT=8899 zsh $D/ui.sh telemetry iPhone-18-Pro HomespunUITests/TelemetryUITests 8798 ;;
    duo-cover)
      run duo-cover zsh $D/ui.sh duo-cover iPhone-Duo \
        HomespunUITests/LibraryUITests,HomespunUITests/ItemViewerUITests,HomespunUITests/ServerTabUITests,HomespunUITests/ServerModeUITests 8795 ;;
    duo-open)
      run duo-open env EXTRA=12 DUO_POSES=1 zsh $D/ui.sh duo-open iPhone-Duo HomespunUITests/DuoLayoutUITests 8793 open ;;
    *)
      echo "unknown run: $one"; failed+=$one ;;
  esac
done
(( ${#failed} == 0 )) || { echo "failed: ${failed[*]}"; exit 1; }
