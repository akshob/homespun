# Homespun

Keep full-quality originals on your own server and compact copies in Apple Photos.

Website: [homespun.photos](https://homespun.photos)

Homespun grew out of [PhotoRelay](https://github.com/akshob/photo-relay).
You pick photos and videos, the originals are stored and verified on your server,
compact copies come back to Apple Photos, and (optionally) the originals are removed
from the iPhone only after the server proves it has an identical copy.

## Modes

1. **On-phone:** the app compresses with Apple's encoders. No server needed for
   compression; originals stay wherever they already are.
2. **Self-hosted:** Homespun Server (Linux, Docker) stores originals and compresses
   with x265, producing the smallest files.
3. **Immich add-on:** the server reads originals from an existing Immich server by API
   key. The app saves compact copies to a "Homespun" album that you exclude from
   Immich backup, so they are not re-uploaded or shown in the Immich timeline.

## Layout

| Target | Platforms | Purpose |
|---|---|---|
| `HomespunCore` | iOS, macOS, Linux | Compression profile, SHA-256/SHA-1 fingerprints, server API types, deletion gate |
| `HomespunMedia` | iOS, macOS, Linux | Media backends. Linux: libvips photos (EXIF copied byte for byte, so Live Photo identifiers survive) and x265 via the `ffmpeg` tool. Apple: ImageIO photos, AVFoundation video and Live Photo motion, `PHLivePhoto` pair validation |
| `HomespunTestSupport` | iOS, macOS | Synthetic photos, Live Photos, and videos for tests (not product code) |
| `HomespunServerKit`, `homespun-server` | Linux, macOS | Hummingbird server: SQLite catalog, pairing, verified uploads, compression jobs, Immich originals |
| `Apps/Homespun` | iOS | SwiftUI app (bundle ID `photos.homespun.app`), uses Core and Media from this package |

Live Photo motion is compressed only with AVFoundation (on the phone or a Mac).
FFmpeg breaks the links between the still and its motion, so iOS no longer treats
the pair as a Live Photo.

## Safety rules

- An original's SHA-256 is its identity.
- The app may delete an original only if the server's copy matches its size and
  SHA-256, and the compact copy was imported and verified (`DeletionGate`). Check
  again at deletion time.
- Deletion always goes through iOS's own confirmation; items stay in Recently
  Deleted. Homespun never empties Recently Deleted.
- Outputs are written to a temporary name, verified (dimensions, audio tracks,
  duration within 0.5 s or 1%, full decode), then published. A video that does not
  get smaller keeps the original.

## Build and test

Requires Swift 6. On Linux, install `libvips-dev` (photo backend) and `ffmpeg` with
libx265 (video and media tests). On macOS SwiftPM warns that it cannot find `vips`; that is
expected, because Apple platforms use ImageIO instead. On a Mac,
`swift test` also runs the Apple backend tests (ImageIO, AVFoundation, `PHLivePhoto`)
on synthetic media.

```bash
swift build
swift test
HOMESPUN_HOST=127.0.0.1 HOMESPUN_PORT=8787 swift run homespun-server
```

To run the media tests on an iOS simulator:

```bash
xcodebuild test -scheme Homespun-Package -only-testing:HomespunMediaTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

If git refuses SwiftPM's dependency cache (`safe.bareRepository is 'explicit'`),
override it for the command only:

```bash
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build
```

## iOS app

On first launch the app explains what it does, connects to a server (found on the network,
by QR code or link, or by address and code), shows the server's self-check, and asks for
Photos access. Compact copies go to a "Homespun" album with the original's date, location,
and favorite and hidden state; edited items are compressed as they currently look. Before the
first removal it explains what removal means (including iCloud Photos), and the first removal
takes at most 10 originals until you confirm the copies look right. Making copies on the
iPhone alone is in Settings; it frees no space, since there is no verified copy elsewhere.

On a Mac with Xcode:

```bash
brew install xcodegen
cd Apps/Homespun && xcodegen generate && open Homespun.xcodeproj
```

The Xcode project is generated from `project.yml` and not committed.

### Running it on your iPhone

A free Apple ID works; apps signed this way stop launching after 7 days until you
install them again.

1. In Xcode, sign in under Settings > Accounts. This creates a "Personal Team".
2. Put the team ID in `Apps/Homespun/Local.xcconfig` (git-ignored):
   `DEVELOPMENT_TEAM = ABCDE12345`. Debug builds use the bundle ID
   `photos.homespun.app.dev`, so a personal team never registers the App Store ID.
3. Connect the iPhone, then turn on Settings > Privacy & Security > Developer Mode.
4. Build and install:

   ```bash
   xcodegen generate
   xcodebuild -project Homespun.xcodeproj -scheme Homespun -configuration Debug \
     -destination 'platform=iOS,name=<your iPhone>' -derivedDataPath build \
     -allowProvisioningUpdates build
   xcrun devicectl device install app --device '<your iPhone>' \
     build/Build/Products/Debug-iphoneos/Homespun.app
   ```

5. On the iPhone, trust the developer under Settings > General > VPN & Device
   Management.

### Trying it on a simulator

```bash
SIM=$(xcrun simctl create "Homespun Demo" com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
  com.apple.CoreSimulator.SimRuntime.iOS-27-2)
xcrun simctl boot "$SIM" && open -a Simulator
# Optional: add your own test media. A still and a MOV with the same name and Live Photo
# content identifier are imported as one Live Photo.
xcrun simctl addmedia "$SIM" IMG_1001.HEIC IMG_1001.MOV IMG_1002.JPG
xcodebuild -project Homespun.xcodeproj -scheme Homespun -destination "id=$SIM" \
  -derivedDataPath build build
xcrun simctl install "$SIM" build/Build/Products/Debug-iphonesimulator/Homespun.app
xcrun simctl launch "$SIM" photos.homespun.app.dev
```

Simulator encoders are slower than an iPhone's and ignore bitrate settings, so sizes
there are only indicative.

### App tests

`HomespunUITests` picks the newest items in the system photo picker and waits for their
compact copies. `HomespunTests` runs the pipeline inside the app on synthetic Live
Photos, photos, and videos and checks the saved copies with PhotoKit. Run both on a fresh
throwaway simulator with photo access granted:

```bash
SIM=$(xcrun simctl create "Homespun Tests" com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
  com.apple.CoreSimulator.SimRuntime.iOS-27-2)
xcrun simctl boot "$SIM" && xcrun simctl privacy "$SIM" grant photos photos.homespun.app.dev
xcodebuild test -project Homespun.xcodeproj -scheme Homespun -destination "id=$SIM"
xcrun simctl delete "$SIM"
```

## Homespun Server

Homespun Server keeps originals and makes the compact copies (x265 for video, libvips on
Linux or ImageIO on a Mac for photos). On a Mac it also compresses Live Photo motion with
AVFoundation, so the phone only downloads and imports; on Linux the phone compresses the
motion, because only AVFoundation keeps the still and its motion paired.

The app's first-run screens walk through setup: "Don't have a server yet? Set one up" shows
the steps for a Mac or Linux (also at [homespun.photos/setup](https://homespun.photos/setup)).
Until packages exist, the server is built from source:

```bash
# Linux (Ubuntu/Debian; the app shows dnf, pacman, and zypper equivalents)
sudo apt install -y git libvips-dev libsqlite3-dev ffmpeg avahi-utils
# macOS: xcode-select --install && brew install ffmpeg

git clone https://github.com/akshob/homespun.git ~/homespun
cd ~/homespun && swift build -c release --product homespun-server
.build/release/homespun-server install-service --data ~/Homespun   # systemd user service or LaunchAgent
.build/release/homespun-server pair                                 # QR code + homespun:// link, 10 minutes
.build/release/homespun-server devices                              # paired devices; `revoke <id>` removes one
```

`install-service` listens on the home network (`0.0.0.0:8787`, unless `HOMESPUN_HOST` is set),
starts with the computer, and saves its settings to `~/.config/homespun/server.env` so later
commands find the same data. If the pairing address is wrong (for example behind a proxy), set
`HOMESPUN_PUBLIC_URL`. The catalog (`homespun.db`, with token hashes and any Immich key) is
readable only by the server's user.
The server advertises itself with Bonjour (`_homespun._tcp`, via `dns-sd` on macOS or
`avahi-publish` on Linux), so the app lists it; pairing still needs the one-time code. You can
also scan the QR code with the iPhone's Camera app, paste the `homespun://pair?…` link (handy
on the simulator), or type the address and code.

After pairing, the app shows the server's self-check (`GET /api/v1/setup`): photo and video
encoders, Live Photos, Bonjour, free space, whether it starts automatically, and Immich, each
with the command that fixes it on that server's system. Install what it asks for, then tap
"Check again".

For now the app talks plain HTTP, and only to servers on the home network (IP addresses and
`.local` names); HTTPS comes later. The server stores originals read-only under
`originals/YYYY/MM/` (by capture month), checks each upload's SHA-256 before accepting it, and
lets the app remove an original only after checking its copy again at that moment
(`POST /api/v1/assets/{id}/verify`).

### Immich mode

If you already run [Immich](https://immich.app) and back up your iPhone with its app, Homespun
Server can use the originals Immich holds instead of storing its own. Connect it from the app
(Settings › Connect Immich): enter Immich's address and an API key created with only the
`asset.read` and `asset.download` permissions. The server tests the key and keeps it; the app
never stores it. (`HOMESPUN_IMMICH_URL` with `HOMESPUN_IMMICH_API_KEY_FILE` also works, until
Immich is disconnected from the app.)

Homespun finds each original by its checksum, downloads it, and checks it byte for byte
against the iPhone's file before making a compact copy. It never uploads to, changes, or
deletes anything in Immich. Items Immich does not have yet show "Not in Immich yet"; pick
them again after the Immich app has backed them up. Edited items and RAW+JPEG pairs are not
supported in Immich mode yet. In the Immich app, exclude the "Homespun" album from backup so
compact copies are not uploaded.

## Website

`site/` holds the static site for [homespun.photos](https://homespun.photos): plain HTML
and CSS, no scripts or build step. It is hosted on Cloudflare Pages (project `homespun`).
To deploy, with a Pages-scoped API token and the account ID in the environment:

```bash
npx wrangler@4 pages deploy site --project-name homespun --branch main
```

## Roadmap

1. Background uploads and downloads (URLSession background sessions), album membership.
2. HTTPS for the server (certificate for a homespun.photos name), Docker image.
3. Demo mode, TestFlight, then the App Store.

## License

- `HomespunCore`, `HomespunMedia`, the iOS app, and tests: [Apache-2.0](LICENSE).
- `homespun-server` (`Sources/HomespunServer`): [AGPL-3.0-only](Sources/HomespunServer/LICENSE).
  If you run a modified server for others over a network, you must offer them its source.

Each source file carries an SPDX license identifier. The name "Homespun" and the
app icon are not licensed under either license; forks must use a different name
and icon.
