#!/bin/zsh
# Builds Homespun for the App Store and uploads it to TestFlight, signing in the cloud with an App
# Store Connect API key (no Xcode account needed). Run on a Mac with Xcode and XcodeGen:
#
#   ASC_KEY_ID=ABC123 ASC_ISSUER_ID=69a6de7e-... Apps/Homespun/scripts/testflight.sh
#
# The team comes from Local.xcconfig (DEVELOPMENT_TEAM = ...), the key from
# ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (or ASC_KEY_PATH). Each upload gets a new
# build number (the time, YYYYMMDDHHMM); the version is MARKETING_VERSION in project.yml.
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
cd "${0:A:h}/.."
: ${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect › Users and Access › Integrations).}
: ${ASC_ISSUER_ID:?Set ASC_ISSUER_ID.}
ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
[[ -f $ASC_KEY_PATH ]] || { echo "No API key at $ASC_KEY_PATH"; exit 1; }
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Local.xcconfig 2>/dev/null | head -1)
[[ -n $TEAM ]] || { echo "Put DEVELOPMENT_TEAM = <Team ID> in Apps/Homespun/Local.xcconfig"; exit 1; }
BUILD=$(date +%Y%m%d%H%M)
WORK=${TMPDIR:-/tmp}/homespun-testflight-$BUILD
AUTH=(-allowProvisioningUpdates -authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID
      -authenticationKeyIssuerID $ASC_ISSUER_ID)

xcodegen generate --quiet
xcodebuild archive -project Homespun.xcodeproj -scheme Homespun -configuration Release \
  -destination generic/platform=iOS -archivePath $WORK/Homespun.xcarchive \
  CURRENT_PROJECT_VERSION=$BUILD "${AUTH[@]}" | grep -E "error:|warning: .*sign|ARCHIVE (SUCCEEDED|FAILED)"

cat > $WORK/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath $WORK/Homespun.xcarchive -exportOptionsPlist $WORK/ExportOptions.plist \
  -exportPath $WORK/export "${AUTH[@]}" | grep -E "error:|Upload|EXPORT (SUCCEEDED|FAILED)"
echo "Uploaded build $BUILD. It shows in App Store Connect › TestFlight after processing (about 10–30 minutes)."
