#!/bin/zsh
# Once per runner account: the performance simulator, an iPhone Duo with 35,000 small synthetic
# photos (about 40 minutes to add). Its UDID goes to $CI_STATE/perf-udid.
set -euo pipefail
source ${0:A:h}/env.sh
COUNT=${1:-35000}
MEDIA=$CI_STATE/media/perf-$COUNT
if [[ ! -f $MEDIA/.done ]]; then
    mkdir -p $MEDIA
    ffmpeg -v error -f lavfi -i "testsrc2=size=320x240:rate=1" -frames:v $COUNT -q:v 6 $MEDIA/IMG_%05d.JPG
    touch $MEDIA/.done
fi
SIM=$(new_simulator iPhone-Duo "HS CI Perf")
xcrun simctl privacy $SIM grant photos photos.homespun.app
ls $MEDIA/*.JPG | xargs -n 500 xcrun simctl addmedia $SIM
echo $SIM > $CI_STATE/perf-udid
echo "performance simulator $SIM with $COUNT photos"
