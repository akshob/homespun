#!/bin/zsh
# Builds Homespun's shipping feature set for the App Store and uploads it to
# TestFlight, signing in the cloud with an App Store Connect API key (Admin). Works over SSH: the
# archive is unsigned (a development certificate would need the login keychain), and the export is
# signed with Apple's cloud-managed distribution certificate. Run on a Mac with Xcode and XcodeGen:
#
#   ASC_KEY_ID=ABC123 ASC_ISSUER_ID=69a6de7e-... Apps/Homespun/scripts/testflight.sh
#
# (or put both in ~/.appstoreconnect/homespun.env). The team comes from Local.xcconfig
# (DEVELOPMENT_TEAM = ...), the key from ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (or
# ASC_KEY_PATH). Each upload gets a new build number (the time, YYYYMMDDHHMM); the version is
# MARKETING_VERSION in project.yml.
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
cd "${0:A:h}/.."
SKIP_EXPORT=${HOMESPUN_SKIP_EXPORT:-0}
if [[ $SKIP_EXPORT != 1 ]]; then
[[ -f ~/.appstoreconnect/homespun.env ]] && { set -a; . ~/.appstoreconnect/homespun.env; set +a; }
: ${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect › Users and Access › Integrations).}
: ${ASC_ISSUER_ID:?Set ASC_ISSUER_ID.}
ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
[[ -f $ASC_KEY_PATH ]] || { echo "No API key at $ASC_KEY_PATH"; exit 1; }
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Local.xcconfig 2>/dev/null | head -1)
[[ -n $TEAM ]] || { echo "Put DEVELOPMENT_TEAM = <Team ID> in Apps/Homespun/Local.xcconfig"; exit 1; }
fi
BUILD=$(date +%Y%m%d%H%M)
WORK=${HOMESPUN_ARCHIVE_WORK:-$PWD/../../ci-results/archive-$BUILD}
mkdir -p "$WORK"
ENABLED=$(sed -n 's/^HOMESPUN_RELEASE_FEATURES = //p' ReleaseFeatures.xcconfig)

check_app() {
  if [[ $ENABLED == NO ]]; then
    [[ ! -d "$1/Watch" ]] || { echo "Release must not embed Watch" >&2; return 1; }
    local extensions=("$1"/PlugIns/*Widgets*.appex(N))
    (( ${#extensions} == 0 )) || { echo "Release must not embed widgets" >&2; return 1; }
    [[ $(/usr/libexec/PlistBuddy -c 'Print :HomespunReleaseFeatures' "$1/Info.plist") == NO ]] \
      || { echo "Release feature setting mismatch" >&2; return 1; }
    echo "Archive contents checked: no widgets, no Watch; release features OFF."
  fi
}

zsh scripts/generate-project.sh
xcodebuild archive -project Homespun.xcodeproj -scheme Homespun -configuration Release \
  -destination generic/platform=iOS -archivePath $WORK/Homespun.xcarchive \
  -derivedDataPath $WORK/dd -clonedSourcePackagesDirPath $WORK/spm \
  CURRENT_PROJECT_VERSION=$BUILD CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$WORK/archive.log" \
  | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" | grep -v appintents
[[ -d $WORK/Homespun.xcarchive ]] || exit 1
# An unsigned bundle has no entitlements, and the export keeps only the ones it finds: sign each bundle
# ad hoc (no certificate needed) with its own, inside out, so the App Group survives.
APP=$WORK/Homespun.xcarchive/Products/Applications/Homespun.app
check_app "$APP"
if [[ $SKIP_EXPORT == 1 ]]; then
  echo "Archive verified; export and upload skipped: $WORK/Homespun.xcarchive"
  exit 0
fi
AUTH=(-allowProvisioningUpdates -authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID
      -authenticationKeyIssuerID $ASC_ISSUER_ID)
ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $APP/Info.plist)
for bundle entitlements in \
    $APP/Watch/HomespunWatch.app/PlugIns/HomespunWatchWidgets.appex HomespunWatchWidgets/HomespunWatchWidgets.entitlements \
    $APP/Watch/HomespunWatch.app HomespunWatch/HomespunWatch.entitlements \
    $APP/PlugIns/HomespunWidgets.appex HomespunWidgets/HomespunWidgets.entitlements \
    $APP Homespun/Resources/Homespun.entitlements; do
  [[ -d $bundle ]] || continue
  sed "s/\$(HOMESPUN_BUNDLE_ID)/$ID/g" $entitlements > $WORK/bundle.entitlements
  codesign --force --sign - --timestamp=none --entitlements $WORK/bundle.entitlements $bundle
done
# Keep the symbols: crash reports (MetricKit) are symbolicated with them (scripts/symbolicate.py).
BUILDS=${HOMESPUN_BUILDS:-$HOME/homespun-builds}
mkdir -p $BUILDS/$BUILD && cp -R $WORK/Homespun.xcarchive/dSYMs/. $BUILDS/$BUILD/

cat > $WORK/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath $WORK/Homespun.xcarchive -exportOptionsPlist $WORK/ExportOptions.plist \
  -exportPath $WORK/export "${AUTH[@]}" | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
[[ -f $WORK/export/Homespun.ipa ]] || exit 1
# Inspect the actual exported IPA too, before any upload.
mkdir -p "$WORK/inspection"
unzip -q "$WORK/export/Homespun.ipa" -d "$WORK/inspection"
check_app "$WORK/inspection/Payload/Homespun.app"
# altool finds the key in ~/.appstoreconnect/private_keys.
xcrun altool --upload-app -f $WORK/export/Homespun.ipa -t ios --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID 2>&1 \
  | grep -E "UPLOAD (SUCCEEDED|FAILED)|ERROR ITMS|error:"
echo "Uploaded build $BUILD. It shows in App Store Connect › TestFlight after processing (about 10–30 minutes):"
echo "  python3 scripts/asc.py wait $BUILD"
