# Homespun

Keep full-quality originals on your own server and compact copies in Apple Photos.

Website: [homespun.photos](https://homespun.photos)

Homespun grew out of [PhotoRelay](https://github.com/akshob/photo-relay).
You pick photos and videos, the originals are stored and verified on your server,
compact copies come back to Apple Photos, and (optionally) the originals are removed
from the iPhone only after the server proves it has an identical copy.

## Modes

Homespun always works with a server you run; the app doesn't compress on its own.

1. **Self-hosted:** Homespun Server on a Mac or Linux computer stores originals and
   compresses with x265, producing the smallest files. A Mac server makes every compact
   copy, Live Photos included; with a Linux server the iPhone compresses Live Photo motion,
   because only Apple's AVFoundation keeps it paired with the photo.
2. **Immich add-on:** the server reads originals from an existing Immich server by API
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

On first launch the app explains what it does, connects to a server (tap one found on the
network: a Mac asks you to click Allow on its screen, a Linux server gives you a code; or use a
QR code, link, or address), shows the server's self-check, and asks for Photos access. A paired
iPhone can add another device from Settings › Add another device (a QR code and one-time code).

The main screen is the whole library as a grid, oldest first like Photos. Tap photos to select
them (or "Select all not backed up"), then Compact; afterwards Homespun offers to free up space
for them. Once an item has a compact copy, the grid shows the copy instead of the original, with
a badge: orange (the original is still on this iPhone; Free up space removes it) or green
(backed up: the original is only on the server). Filters show everything, only what isn't backed
up, or only what is. Compact copies go to a "Homespun" album with the original's date, location,
and favorite and hidden state; edited items are compressed as they currently look. Before the
first removal it explains what removal means (including iCloud Photos), and the first removal
takes at most 10 originals until you confirm the copies look right.

**Premium** (one-time In-App Purchase; everything above stays free):

- **Automatic mode**: new photos and videos (or, if chosen, everything not backed up yet) are
  backed up and compacted without being selected: when the app opens and in a background
  processing task iOS runs when it chooses, usually overnight while charging. Removing
  originals still waits for you; a notification says when there is space to free up. Items
  added later with older dates (synced, saved) are found through Photos' change history.
- **Cloud copies**: the server's connectors (see below).

Builds made in Xcode (Debug) have Premium unlocked; release builds check the App Store.
`Homespun.storekit` is a local App Store for trying the purchase on the simulator.

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
.build/release/homespun-server install-service --data ~/Pictures/Homespun   # copies to ~/.local/bin, starts it
~/.local/bin/homespun-server pair                                   # QR code + homespun:// link, 10 minutes
~/.local/bin/homespun-server devices                                # paired devices; `revoke <id>` removes one
```

`install-service` copies the server to `~/.local/bin/homespun-server` (rerun it after
rebuilding to update), listens on the home network (`0.0.0.0:8787`, unless `HOMESPUN_HOST` is
set), starts with the computer, and saves its settings to `~/.config/homespun/server.env` so later
commands find the same data. If the pairing address is wrong (for example behind a proxy), set
`HOMESPUN_PUBLIC_URL`. The catalog (`homespun.db`, with token hashes and any Immich key) is
readable only by the server's user.
The server advertises itself with Bonjour (`_homespun._tcp`, via `dns-sd` on macOS or
`avahi-publish` on Linux, from avahi-utils; a running server notices it within seconds of being
installed), so the app lists it. Tapping a Mac server asks the person at its screen to click
Allow (a dialog from the LaunchAgent; the Mac and the iPhone show the same 4-digit number, and
the server asks about one device at a time). Linux servers, or a Mac server started over SSH,
need the one-time code from `pair` instead: scan its QR code with the iPhone's Camera app,
paste the `homespun://pair?…` link (handy on the simulator), or type the code.

After pairing, the app shows the server's self-check (`GET /api/v1/setup`): photo and video
encoders, Live Photos, Bonjour, free space, whether it starts automatically, and Immich, each
with the command that fixes it on that server's system. Install what it asks for, then tap
"Check again".

For now the app talks plain HTTP, and only to servers on the home network (IP addresses and
`.local` names); HTTPS comes later. The server checks each upload's SHA-256 before accepting it,
stores originals read-only, and lets the app remove an original only after checking its copy
again at that moment (`POST /api/v1/assets/{id}/verify`).

Originals go in a folder per phone, by capture month: `<originals>/<phone name>/YYYY/MM/`
(the phone's name when it paired; renaming the phone later keeps the folder). The originals
folder is `<data>/originals` unless `install-service --originals DIR` (or `HOMESPUN_ORIGINALS`)
says otherwise, so the catalog and originals can live apart: for example `--data
/Volumes/Homespun/.homespun --originals /Volumes/Homespun` on a Mac with a Homespun volume
(`diskutil apfs addVolume disk3 APFS Homespun` adds one that shares the disk's free space). The
server never creates a folder whose parent is missing, so a disk that isn't connected isn't
silently replaced by a folder on the startup disk; the self-check says so instead. To change
the folder later, use the app (Settings › Originals folder › Change folder): the server copies
every original there, checks each one, holds new backups for a moment while it switches, and
only then removes the old copies. A move interrupted by a restart picks up where it left off.

### Cloud copies (connectors)

The server can also copy each original somewhere else once it has stored and checked it, as
an extra backup (Settings › Cloud copies in the app). Copies never count toward removing an
original from the iPhone; only the server's own verified copy does. Each copy is checked
where the service allows it, and a full or offline destination is retried later without
holding up compact copies.

- **OneDrive**: sign in from the app with a code. Homespun asks only for its own app folder
  (`Apps/Homespun` in OneDrive) and checks every upload against OneDrive's QuickXorHash.
  Until Homespun ships its own Microsoft app ID, set `HOMESPUN_ONEDRIVE_CLIENT_ID` to the
  ID of a Microsoft app registration (public client, device code flow, delegated
  `Files.ReadWrite.AppFolder`, `User.Read`, `offline_access`).
- Your own connectors: implement `Connector` and build a server binary that calls
  `ServerCommand.run(connectors: [YourConnector()])` from its `main`, depending on the
  `HomespunServerKit` library product.

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
compact copies are not uploaded. The self-check looks up the latest 40 compact copies in
Immich and warns if any were uploaded; delete those in Immich yourself, since Homespun's key
can only read.

### Bringing in an existing library

If you already keep originals on the server's disks and made compact copies some other way
(for example with your own scripts, imported into Photos with PhotoSync), tell Homespun Server
about them so the app recognises those copies instead of backing them up as originals:

```sh
homespun-server import library.jsonl --dry-run   # checks the files, records nothing
homespun-server import library.jsonl             # hashes the originals and records them
```

It runs beside a running server, and running it again is safe (finished items are skipped).
By default the originals stay where they are: Homespun reads them, never moves, changes, or
deletes them, and hashes them again where they are whenever the app checks an item. With
`--copy`, each is copied into the originals folder under `--folder NAME` (default "Camera
Roll"), hashed as it's read (once, so a network share is read once) and checked again on disk,
and then kept like an uploaded original; the source is still only read. `--jobs N` reads N
files at a time (default 4). Each line of the manifest is one item:

```json
{"kind": "live_photo", "capture_date": "2024-03-16T22:58:48Z",
 "originals": [{"role": "photo", "path": "/archive/2024/03/IMG_3139.HEIC"},
               {"role": "paired_video", "path": "/archive/2024/03/IMG_3139.MOV"}],
 "copies": [{"role": "photo", "sha256": "1d4f…"}, {"role": "paired_video", "sha256": "eb3c…"}]}
```

`kind` is `photo`, `live_photo`, or `video`. `copies` lists the SHA-256 of each compact file
as it is on the phone (Photos keeps imported files byte for byte, though it may rename them).
An original may carry `"sha256"` and `"sha1"` (as recorded when it was fetched, or as a cloud
service reports it) to make sure it hasn't changed.

Then, in the app, open Settings › Find compact copies made elsewhere. It hashes the photos and
videos Homespun doesn't know yet and asks the server about them (`POST /api/v1/copies/lookup`;
only hashes leave the phone). Copies it finds count as backed up and join the Homespun album;
an original still on the phone whose copy is found becomes ready to free up. It also restores
what Homespun knew after reinstalling the app or moving to a new iPhone.

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
