#!/bin/zsh
# A set of UI test runs, one after another (each on its own simulator and server); fails if any
# did. The lanes run on separate runners at the same time, so their ports differ.
#   lane.sh smoke | iphone | duo
set -u
D=${0:A:h}
failed=()
run() { local name=$1; shift; echo "::group::$name"; "$@" || failed+=$name; echo "::endgroup::"; }
case $1 in
  smoke)
    run smoke zsh $D/ui.sh smoke iPhone-18-Pro HomespunUITests/LibraryUITests,HomespunUITests/ServerTabUITests/testRenameThisIPhone 8790
    ;;
  iphone)
    run iphone zsh $D/ui.sh iphone iPhone-18-Pro \
      HomespunUITests/ItemViewerUITests,HomespunUITests/ServerTabUITests,HomespunUITests/ServerModeUITests,HomespunUITests/PremiumUITests 8794
    # A bigger library (the newest cells far from the oldest; the filter crash needed it).
    run library env EXTRA=200 zsh $D/ui.sh library iPhone-18-Pro HomespunUITests/LibraryUITests 8799
    run later zsh $D/later.sh later iPhone-18-Pro 8796
    run copies zsh $D/copies.sh copies 8792
    # These expect a fresh install of their own.
    run onboarding zsh $D/ui.sh onboarding iPhone-18-Pro HomespunUITests/OnboardingUITests 8797
    run telemetry env STUB_PORT=8899 zsh $D/ui.sh telemetry iPhone-18-Pro HomespunUITests/TelemetryUITests 8798
    ;;
  duo)
    run duo-cover zsh $D/ui.sh duo-cover iPhone-Duo \
      HomespunUITests/LibraryUITests,HomespunUITests/ItemViewerUITests,HomespunUITests/ServerTabUITests,HomespunUITests/ServerModeUITests 8795
    run duo-open env EXTRA=12 DUO_POSES=1 zsh $D/ui.sh duo-open iPhone-Duo HomespunUITests/DuoLayoutUITests 8793 open
    ;;
esac
(( ${#failed} == 0 )) || { echo "failed: ${failed[*]}"; exit 1; }
