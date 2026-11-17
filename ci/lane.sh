#!/bin/zsh
# UI test runs, each on its own simulator and temporary server; fails if any did. GitHub's machines
# take one run each (the ci workflow's matrix); on one Mac, name several, or a group.
#   lane.sh <run|group> ...
#   runs:   quick quick-duo (a pull request's) · iphone library later copies onboarding telemetry
#           duo-cover duo-open (after a merge) · large (nightly)
#   groups: pr (both quick runs), iphone-all, duo-all, full (every run after a merge)
# Ports differ, so runs of different jobs can share a Mac. RETRY_UI=1: a failed run gets one more
# try on a new simulator; the first try's results move to $RESULTS/attempt1 (the summary marks a
# run that passed then as flaky).
set -u
D=${0:A:h}
failed=()
source $D/env.sh
run() {
    local name=$1; shift
    echo "::group::$name"
    if ! "$@"; then
        if [[ -n ${RETRY_UI:-} ]]; then
            echo "$name failed; one more try"
            mkdir -p $RESULTS/attempt1
            for f in $RESULTS/$name{.xcresult,.log,-server.log,-poses.log,-shots}(N); do mv $f $RESULTS/attempt1/; done
            "$@" || failed+=$name
        else
            failed+=$name
        fi
    fi
    echo "::endgroup::"
}
runs=()
for name in "$@"; do
  case $name in
    pr) runs+=(quick quick-duo) ;;
    iphone-all) runs+=(iphone library later copies onboarding telemetry) ;;
    duo-all) runs+=(duo-cover duo-open) ;;
    full) runs+=(iphone library later copies onboarding telemetry duo-cover duo-open) ;;
    *) runs+=($name) ;;
  esac
done
for one in $runs; do
  case $one in
    quick)
      # A pull request's iPhone run: pair, back up, compare, Keep Original, free up; the viewer;
      # Select All; rename this iPhone.
      run quick zsh $D/ui.sh quick iPhone-18-Pro \
        HomespunUITests/ItemViewerUITests/test1ViewerDetailsAndCompare,HomespunUITests/LibraryUITests/testSelectAllMarksEveryCell,HomespunUITests/ServerModeUITests/test1CompactThroughServerAndRemoveOriginals,HomespunUITests/ServerTabUITests/testRenameThisIPhone 8780 ;;
    quick-duo)
      # A pull request's iPhone Duo run: open, in every pose (layouts, Free Up Space, the viewer).
      run quick-duo env EXTRA=12 DUO_POSES=1 zsh $D/ui.sh quick-duo iPhone-Duo HomespunUITests/DuoLayoutUITests 8782 open ;;
    large)
      # Nightly: a library of 3,000 photos.
      run large env EXTRA=3000 TEST_RUNNER_HOMESPUN_LIBRARY_SIZE=3003 zsh $D/ui.sh large iPhone-18-Pro HomespunUITests/LargeLibraryUITests 8783 ;;
    iphone)
      run iphone zsh $D/ui.sh iphone iPhone-18-Pro \
        HomespunUITests/ItemViewerUITests,HomespunUITests/ServerTabUITests,HomespunUITests/ServerModeUITests,HomespunUITests/PremiumUITests 8794 ;;
    library)
      # A bigger library (the newest cells far from the oldest; the filter crash needed it; paging
      # through items and turning the iPhone needs a few).
      run library env EXTRA=200 zsh $D/ui.sh library iPhone-18-Pro \
        HomespunUITests/LibraryUITests,HomespunUITests/ItemPagingUITests 8799 ;;
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
      run duo-open env EXTRA=12 DUO_POSES=1 zsh $D/ui.sh duo-open iPhone-Duo \
        HomespunUITests/DuoLayoutUITests,HomespunUITests/ItemPagingUITests 8793 open ;;
    *)
      echo "unknown run: $one"; failed+=$one ;;
  esac
done
(( ${#failed} == 0 )) || { echo "failed: ${failed[*]}"; exit 1; }
