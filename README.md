# Homespun

### Optional wake relay (dormant; not part of 1.1.0)

Homespun 1.1.0 ships without it: the app shows no Background Wakeups setting, never registers for
remote notifications and sends no push token. `homespun-notify` remains unreleased infrastructure
for content-free APNs background hints.
It is not started by `homespun-server`, has not been deployed as part of this change, and does
not make iOS background execution or delivery guaranteed. The result cursor remains authoritative.
Deployment and any hosting spend require a separate owner decision.

The relay receives an opaque route, its generation and a random hint nonce, not media, hashes,
file names, server addresses or progress. The iPhone's APNs token is kept only by the relay;
the home server gets a route-scoped send credential, never the provider key or device token.
Requests and provider failures are not logged with tokens or payloads. Pending enrollments expire
after a day; active enrollments expire after 90 days without a device refresh, or are removed on
opt-out or an invalid-token response. A hint does not extend that lifetime.

Enrollment is deliberately two-phase. Before contacting the relay, the app must persist its
route UUID and separate management/send secrets in device-only Keychain. A tokenless
`POST /v1/routes/{id}/begin` returns a fresh server generation. Only after persisting that
generation may the app `PUT /v1/routes/{id}` with the token and send secret. A late activation
cannot recreate a deleted enrollment: activation never creates a row, and a late begin receives a
different generation. Disabling consent fences and joins pending client registrations, then
retries authenticated `DELETE` until acknowledged. No permanent APNs-token tombstone is needed.

The separate service listens only on loopback behind an explicitly configured public HTTPS
frontend. Run `homespun-notify --help` for private environment configuration; it requires its own
data folder and an owner-readable-only APNs `.p8` file. Never put that key, its contents or a
team's private signing configuration in this repository, an iPhone build or logs. TestFlight uses
production APNs; the development app needs its own topic/environment and appropriate key scope.
The relay coalesces hints to at most one attempt per route every 20 minutes, with fenced leases
and retryable durable state. The generic payload contains only `content-available`.

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
| `Apps/Homespun` | iOS, watchOS | SwiftUI app (bundle ID `photos.homespun.app`), uses Core and Media; widgets and Apple Watch are planned, not shipped in 1.0.0 |
| `services/telemetry` | Cloudflare Workers | Opt-in analytics, MetricKit reports and problem reports from the app (`telemetry.homespun.photos`) |

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
- Live Photo motion held unchanged still has to decode before its byte-identical copy is
  published. Cancellation stops its reader/writer and joins the media lanes before removing
  the unpublished file.

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

Version 1.1.0 is being prepared for TestFlight and supports iOS 26 and later.
The public App Store release is still 1.0.0. Release build numbers are timestamps from `testflight.sh`.

On first launch the app explains what it does, connects to a server (tap one found on the
network: a Mac asks you to click Allow on its screen, a Linux server gives you a code; or use a
QR code, link, or address), shows the server's self-check, and asks for Photos access. A paired
iPhone can add another device from Server › Devices › Add Another Device (a QR code and one-time code).

The main screen is the whole library as a grid, oldest first like Photos. Tap photos to select
them (or "Select all not backed up"), then Compact; afterwards Homespun offers to free up space
for them. Once an item has a compact copy, the grid shows the copy instead of the original, with
a badge: orange (the original is still on this iPhone; Free up space removes it) or green
(backed up: the original is only on the server). Filters show everything, only what isn't backed
up, or only what is. Compact copies go to a "Homespun" album with the original's date, location,
and favorite and hidden state; edited items are compressed as they currently look. Before the
first removal it explains what removal means (including iCloud Photos) and shows the compact
copies to compare with their originals (from the server); "They Look Right" frees them up. Setup
and the Get Started card open the Library to pick a few items to try.
For a requested compact copy, once the server retains the original, "Compact copy in progress"
covers both making the copy on the server and saving it to this iPhone. Details distinguishes those
steps; the item is not ready to free up until its saved copy is verified.
Ready items can be reviewed from Free Up while other backups continue. Confirming removal waits
for local backup work to stop; backups can be paused in Activity.

Videos play in the item viewer, with Play/Pause and a position slider below the picture.
The viewer zooms over the whole app from the tapped thumbnail, without changing the tabs or
the Library's layout. Back or a downward swipe returns it to the thumbnail of the item shown.
Connection and backup messages also float above the content: appearing or disappearing changes
the scroll range, not the visible cells, tabs or title.
Autoplay follows the iPhone's accessibility setting. On the open iPhone Duo, Compare can show
both videos side by side: they play, pause, seek and zoom together, with sound from one copy
at a time. Sound switches between the original and the compact copy.

**Try the Demo** (on the first setup page, and in Server › Help and About) shows all of this without
a server: about 30 sample photos and videos drawn for the purpose. The photos, a screenshot and the
grid's pictures are drawn on the iPhone when the demo starts ("Preparing the Demo", a few seconds,
once per launch; `Features/Demo/DemoArt.swift`). The videos and a Live Photo come with the app
(`Resources/Demo`, about 3.4 MB, made by `scripts/demo-media.sh` from the same drawing code).
The pretend server, "Homespun Demo",
is found as if on the Wi‑Fi, pairs by itself, and answers the app's server calls inside the app.
Backing up, compact copies, Compare, Free Up Space (with a question that says nothing is deleted),
Keep Original, Restore Original, Activity and the Server tab all work on them. The demo never reads or
changes Photos, asks iOS for nothing, records no analytics and sends no reports. Without a paired real
server, future feature-enabled builds can share its live status with widgets and Apple Watch; this is off
in 1.0.0. With a paired server, its real status is never replaced. The demo's settings
and records are kept apart and deleted by Leave the Demo (the Server tab, or the Demo mark in setup).
Leaving the demo deletes what it did; the drawn photos stay until Homespun next starts from scratch.
The demo has the same release scope as the app.

Upgrading removes the former reviewer-code Keychain item once at launch, retrying on a later
launch if the Keychain is unavailable. The demo uses only drawn and bundled media, with no downloads.

**Premium in 1.1.0** (one-time purchase with Family Sharing; not available in the public 1.0.0 app):

- **Automatic mode**: new photos and videos (or, if chosen, everything not backed up yet) are
  backed up and compacted without being selected: when the app opens and in a background
  processing task iOS runs when it chooses, usually overnight while charging. Removing
  originals still waits for you; a notification says when there is space to free up. Items
  added later with older dates (synced, saved) are found through Photos' change history.
  - **Compact copies later**: originals go home right away, but compact copies are made only
    once an item is older than a cutoff you set with a slider (Right Away, 1 Week, 1 Month
    (default), 2 Months, 3 Months), counted from when it was taken or added, whichever is later.
    Until then the item shows "Backed up" and the server retains its complete original, sending no
    compact copy back. Favorites can be kept as they are. Backing up by hand compacts right away.
  - **Cleaned-up items**: version 1.1.0 requests permanent retention, including recent Automatic
    backups. Deleting an item in Photos does not withdraw its server claim or move its original to
    server trash. Legacy deferred cleanup is not applied to these backups, and no existing permanent
    request is reclassified as temporary.
- **Widgets**: what's ready to free up (size and items), the last backup (when, how many), whether
  the server can be reached (by name) and Automatic Mode ("Tonight while charging", "Off"), on the
  Home Screen (small, medium), the Lock Screen (circular, rectangular, inline) and Apple Watch
  (circular, rectangular, inline, corner, and the Smart Stack, higher up when there's space to free
  or the server can't be reached). Tapping one opens that place in the app. Locked, they say
  "Unlock widgets in the Homespun app" and open the unlock sheet (`homespun://unlock?feature=widgets`).
- **Apple Watch**: the same private, offline status on your wrist, with complications and the Smart Stack.
- **OneDrive Cloud Copies**: the server copies verified originals into its own OneDrive app folder.
  Tokens stay on your server; these extra copies never replace the server proof required to free up space.

Automatic Mode's page (Server › Backups) opens with or without the purchase. Turning it on asks for the
purchase first, with Restore Purchase, then carries on; one purchase unlocks Automatic Mode, widgets,
Apple Watch and OneDrive Cloud Copies, with Family Sharing. The local StoreKit configuration is for testing only.
The server's connector support stays available separately (see below).

**Release feature scope:** `Apps/Homespun/ReleaseFeatures.xcconfig` is the single shipping switch:
`HOMESPUN_RELEASE_FEATURES = YES` in 1.1.0 enables Premium, Automatic Mode, OneDrive Cloud Copies,
widgets and Apple Watch together. The public 1.0.0 release used `NO`, omitted those targets and
never queried purchase products or entitlements. Regenerate with
`zsh Apps/Homespun/scripts/generate-project.sh` after changing the switch.
All targets remain in `project.yml`. The generator's `--testing` option selects
`project-features.yml` to embed widgets and Watch for CI, without changing the shipping switch.
Debug can explicitly enable runtime features with `-releaseFeatures YES` or `HOMESPUN_RELEASE_FEATURES=1`;
`-releaseFeatures NO` overrides the environment for release-scope regression tests.
Release ignores both overrides. The Homespun test scheme opts in, as do feature UI tests.
`HomespunReleaseScope` runs the disabled-feature unit regression separately.
Debug feature-enabled builds are unlocked unless `-premiumLocked YES` is set.
Feature-enabled TestFlight builds retain the existing sandbox-product policy.
`Homespun.storekit` is a local App Store for trying the purchase on the simulator.

Automatic background scheduling remains conditional on the purchase and the person's choice.
User-started backups do not require Premium. The App Group shares only the status needed by widgets
and Apple Watch. Disabled-feature regression builds drop purchase telemetry, including queued events
from older builds. The website continues to describe the public 1.0.0 release until 1.1.0 is released.
`HOMESPUN_SKIP_EXPORT=1 zsh Apps/Homespun/scripts/testflight.sh` makes and checks an unsigned archive
without credentials, export or upload. Normal uploads check both the archive and exported IPA for
the required feature setting, every expected embedded target, its bundle identity and matching
version/build numbers. Disabled-feature archives must omit widgets and Watch.

On a Mac with Xcode:

```bash
brew install xcodegen
cd Apps/Homespun && zsh scripts/generate-project.sh && open Homespun.xcodeproj
```

The Xcode project is generated from `project.yml` and not committed.

### Widgets and Apple Watch (Premium in 1.1.0)

The widgets never use the network. Whenever what they show changes (a backup, freeing up space,
the server's answer, Automatic Mode, Premium), the app writes a small status (`Shared/StatusSnapshot.swift`:
counts, sizes, dates and the server's name; no photos, file names or addresses) into the App Group
`group.photos.homespun.app` (`.dev` for Debug builds), at most every few seconds and off the main thread,
and asks WidgetKit to redraw only when the facts changed. It sends the same status to the watch with
WatchConnectivity (the application context, and complication data when the facts changed). Homespun on
Apple Watch (`HomespunWatch`, watchOS 26, installed with the iPhone app) keeps it in its own App Group
for its widgets and shows it on one screen; it can't reach the server itself, so it says how old the
news is and, after 6 hours, "Open Homespun on your iPhone". Relative dates are drawn by the system, so
they stay current without redrawing.

| Target | Bundle ID | Source |
|---|---|---|
| `HomespunWidgets` (iPhone widgets) | `photos.homespun.app.widgets` | `Widgets/`, `Shared/` |
| `HomespunWatch` (watch app) | `photos.homespun.app.watchkitapp` | `HomespunWatch/`, `Shared/` |
| `HomespunWatchWidgets` (watch widgets) | `photos.homespun.app.watchkitapp.widgets` | `Widgets/`, `Shared/` |

Debug builds add `.dev` after `photos.homespun.app`, like the app. Links from the widgets:
`homespun://free-up`, `activity`, `server`, `automatic` and `unlock?feature=widgets`. Debug builds
generated with `--testing` and launched with `-releaseFeatures YES -widgetDemo ready|away|nothing|locked|unpaired`
show made-up facts in the widgets.
`HomespunWidgetTests` draws every size in every state; with `TEST_RUNNER_HOMESPUN_WIDGET_SHOTS=<folder>`
it saves them as PNGs, and `WidgetGalleryUITests` (not in CI) adds the real widgets to the simulator's
Home Screen from the widget gallery and saves screenshots there too.
The watch's Debug-only `-watchDemo fresh|stale` seeds synthetic status; `-watchDemoLater` instead
delivers it three seconds after launch. `HomespunWatchUITests` times Crown and swipe steps for each
case, including a minute refresh (`zsh ci/lane.sh watch`, no paired iPhone or server needed).

### TestFlight

With an Apple Developer Program membership: register the bundle ID `photos.homespun.app`, create
the app in App Store Connect, create an App Store Connect API key (Admin) and save it as
`~/.appstoreconnect/private_keys/AuthKey_<key id>.p8`, put your team in `Local.xcconfig`, then:

```bash
ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> Apps/Homespun/scripts/testflight.sh
```

It archives a Release build without signing (so it works over SSH, where the login keychain is
locked), signs each bundle ad hoc with its entitlements (the App Group; an unsigned bundle has none
for the export to keep), signs the export with Apple's cloud-managed distribution certificate
(registering the widgets' and the watch app's bundle IDs as needed; if it says the App Group isn't
allowed, add `group.photos.homespun.app` in Certificates, Identifiers & Profiles › App Groups and turn
on App Groups for `photos.homespun.app` and its `.widgets`, `.watchkitapp` and `.watchkitapp.widgets`),
uploads it with `altool`, and gives it a new build number. `scripts/asc.py` talks to the App Store Connect API
with the same key: `asc.py testers` creates the internal group "Homespun Team" (every build, no
review) and adds the team's users, `asc.py wait` waits for processing, `asc.py builds` lists builds,
`asc.py crashes` fetches testers' crash feedback and crash logs. TestFlight itself asks testers to
share after a crash (that prompt can't be turned off and appears only in TestFlight builds); Homespun's
own "quit unexpectedly" prompt on the next launch offers Report a Problem.
Install with the TestFlight app.

### Running it on your iPhone

The app, its widgets and the Apple Watch app share an App Group (`group.<bundle ID>`), which only a
paid Apple Developer Program team can use. A free Apple ID's "Personal Team" works without it: add
`CODE_SIGN_ENTITLEMENTS=` to the `xcodebuild` command below (or remove App Groups under Signing &
Capabilities in Xcode, until the next `xcodegen generate`); everything works except the widgets and
the watch, which then say "Open Homespun". Apps signed by a Personal Team stop launching after 7 days
until you install them again.

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

#### Performance tests

Libraries run to tens of thousands of items, so the app is tested at that size with budgets
from Apple's guidance (a tap answered within 100–250 ms, scrolling with at most 10 ms of hitches
per second). Both suites run in the `Profile` configuration (optimised like a release, plus
testability) with the `HomespunPerf` scheme:

- `HomespunTests/PerformanceTests` (unit, a synthetic 35,000-item library): building the grid's
  state and data for each filter, applying job changes, Select All, automatic mode's plan, the
  ledger (recording an item appends to a journal instead of rewriting the file), the history,
  and the library snapshot that shows the grid at launch.
- `HomespunUITests/PerformanceUITests` (a simulator with 35,000 photos): launch to the grid,
  opening and paging items, filters, Select All, tabs, grid sizes and lists. The app measures
  itself with `-perfMonitor YES` (frames while scrolling, interaction times, also written to
  `Documents/perf-monitor.txt`), and with `-perfAutoscroll` scrolls the grid by itself at set
  speeds: the test runner's gestures make the app walk its accessibility tree on the main thread,
  so gesture checks use Apple's "warning" line (25 ms/s) and the autoscroll the "good" one.

The scrolling budgets need a large library: fill a simulator with synthetic photos first (the
maintainers' scripts are `perf-library.sh`, `perf-unit.sh` and `perf-ui.sh`; Instruments traces
with `xctrace` show where main-thread time goes).

## Homespun Server

Homespun Server keeps originals and makes the compact copies (x265 for video, libvips on
Linux or ImageIO on a Mac for photos). On a Mac it also compresses Live Photo motion with
AVFoundation, so the phone only downloads and imports; on Linux the phone compresses the
motion, because only AVFoundation keeps the still and its motion paired.

The app's first-run screens walk through setup: "Don't have a server yet? Set one up" shows
the steps for a Mac or Linux (also at [homespun.photos/setup](https://homespun.photos/setup)).
On a NAS, use the Docker image ([Run on a NAS with Docker](#run-on-a-nas-with-docker)).
Otherwise, until packages exist, the server is built from source:

```bash
# Linux (Ubuntu/Debian; the app shows dnf, pacman, and zypper equivalents)
sudo apt install -y git libvips-dev libsqlite3-dev ffmpeg avahi-utils
# macOS: xcode-select --install && brew install ffmpeg

git clone https://github.com/akshob/homespun.git ~/homespun
cd ~/homespun && swift build -c release --product homespun-server
.build/release/homespun-server install-service --data ~/Pictures/Homespun   # copies to ~/.local/bin, starts it
~/.local/bin/homespun-server pair                                   # QR code + homespun:// link, 10 minutes (--minutes N)
~/.local/bin/homespun-server devices                                # paired devices; `revoke <id>` removes one
~/.local/bin/homespun-server certificate                            # server key and curl's public-key pin
```

`install-service` copies the server to `~/.local/bin/homespun-server` (rerun it after
rebuilding to update), listens on the home network (`0.0.0.0:8787`, unless `HOMESPUN_HOST` is
set), starts with the computer, and saves its settings to `~/.config/homespun/server.env` so later
commands find the same data. If the pairing address is wrong (for example behind a proxy), set
`HOMESPUN_PUBLIC_URL`. The catalog (`homespun.db`, with token hashes and any Immich key) is
readable only by the server's user. Connections use HTTPS on the same port, 8787; plain HTTP is not
accepted. On first start the server creates its encryption identity in `<data>/tls/identity.pem`
(owner-only). Back up the entire `tls` folder with `homespun.db*`, the saved server settings, and
your originals. Keep those backups private: the identity contains the server's private key.
The server advertises itself with Bonjour (`_homespun._tcp`, via `dns-sd` on macOS or
`avahi-publish` on Linux, from avahi-utils; a running server notices it within seconds of being
installed), so the app lists it. Tapping a Mac server asks the person at its screen to click
Allow (a dialog from the LaunchAgent; compare the same 6-digit number on the Mac and the iPhone,
then confirm the match on the iPhone; the server asks about one device at a time). Linux servers, or a Mac server started over SSH,
need the one-time code from `pair` instead: scan its QR code with the iPhone's Camera app,
paste the `homespun://pair?…` link (handy on the simulator), or type the code. Codes work once,
for 10 minutes after `pair`, or 2 minutes after their first pairing check.

After pairing, the app shows the server's self-check (`GET /api/v1/setup`): photo and video
encoders, Live Photos, Bonjour, free space, whether it starts automatically, and Immich, each
with the command that fixes it on that server's system. Install what it asks for, then tap
"Check again".

The app encrypts every server connection with TLS 1.2 or newer and checks the server's public-key
fingerprint (SPKI). QR codes and links carry `fp`; Mac approval compares a number bound to the
key both sides see; typed codes authenticate the server before the code is sent. Bonjour is a
discovery hint, never a source of trust. Existing pairings upgrade automatically over TLS using a
proof of the pairing token, without sending the token before the key is confirmed. Compare the
key in Server Check with `homespun-server certificate` once after upgrading: a token intercepted
before encryption was added could otherwise impersonate the old pairing.

If DHCP changes the server's address, the app looks for it again with Bonjour, preferring its
saved service name. Names and TXT fingerprints only order candidates: a tokenless HTTPS probe
must observe the already-pinned key before the app moves its URL-keyed credentials and retries.
Searches are limited to once a minute, including on activation. Server Check shows the current
address and “Found … at its new address” after a move. Existing pairings learn their service name
on their next successful contact; a legacy pairing at a stale address can first authenticate its
TLS upgrade with the permanent token proof, without sending the token to candidates.

Certificates renew automatically with the same key. `homespun-server certificate --renew` renews
one by hand; `certificate --new-key` keeps a private backup of the previous identity and replaces
the key. The running server reloads it within 10 seconds. Paired iPhones confirm the replacement
with their pairing and show a notice; a changed key with a failed proof blocks backups and Free Up Space.
Transient check failures keep the existing pin and retry automatically after 60 seconds, backing off
to at most 15 minutes; activation and background preparation also retry. A corrupt
identity stops the server rather than silently replacing the key.

Foreground reachability checks share that HTTPS verification path. They keep the last status
while checking; a known-good server gets a second 12-second attempt before a network failure
shows “Can't reach”. Pin mismatches go straight to proof verification, never an ordinary network
retry. Rechecking an existing pin keeps the last status visible until verification concludes.

The server checks each upload's SHA-256 before accepting it,
stores originals read-only, and lets the app remove an original only after checking its copy
again at that moment (`POST /api/v1/assets/{id}/verify`). All API routes are HTTPS-only. Pairing uses
`POST /api/v1/pair/challenge`, then `/pair` with the challenge ID, or commitment/reveal approval at
`/pair/requests` and `/pair/requests/{id}/reveal`, followed by `/pair/requests/{id}/complete`
only after owner approval and the iPhone's confirmation. The installation ID is withheld until
that pinned completion request. `POST /api/v1/tls/verify` permanently supports
verified upgrades and replacement keys without rotating an existing pairing token. Installation-aware
re-pairing adds the catalog migration described below.
If processing fails in files mode, "Try Again" re-registers the item and retries processing
using originals the server already holds and has verified; they don't need to be uploaded again.

Originals go in a folder per phone, by capture month: `<originals>/<phone name>/YYYY/MM/`
(the phone's chosen name; renaming it from the app moves its folder). The originals
folder is `<data>/originals` unless `install-service --originals DIR` (or `HOMESPUN_ORIGINALS`)
says otherwise, so the catalog and originals can live apart: for example `--data
/Volumes/Homespun/.homespun --originals /Volumes/Homespun` on a Mac with a Homespun volume
(`diskutil apfs addVolume disk3 APFS Homespun` adds one that shares the disk's free space). The
server never creates a folder whose parent is missing, so a disk that isn't connected isn't
silently replaced by a folder on the startup disk; the self-check says so instead. To change
the folder later, use the app (Server › Originals Folder › Change Folder): the server copies
every original there, checks each one, holds new backups for a moment while it switches, and
switches the catalog to the new folder. Previous good copies remain pending safe cleanup;
their old roots are recorded in the catalog. A move interrupted by a restart keeps its plan.

### Versioned foreground backups

The authenticated `/api/v2` API separates original retention, processing, and delivery.
Capabilities advertise only `foreground_offset`: this is **not native/background resumable
upload support**. Transfers may stop when the app is closed; opening the app resumes selected
backups from the server's durable upload offset and fetches compact copies finished while it was
closed, without selecting the items again. Manual/permanent claims survive cancellation and missing import acknowledgements;
`compact: false` can still request permanent original retention. Existing ambiguous trash is retained
after migration, not given a new expiry. Versioned deferred claims are explicit and currently retained
without automatic expiry; they do not authorize a permanent deletion proof.

Create an idempotent request at `POST /api/v2/backup-requests`, then use its request ID or
`GET /api/v2/backup-requests?operation_id=<UUID>` after a lost response. Every receipt has a
per-request monotonic `revision`; the change feed's `sequence` is a separate global cursor.
An operation lookup returns one receipt, or HTTP 404 if it has not been admitted, never an array.
Commands use `POST /api/v2/backup-requests/<id>/commands` with the exact expected version.
Server-side photo and video lanes progress independently within shared codec/storage limits.
Versioned originals keep their phone/capture-month folders and readable names, with an immutable
manifest-qualified directory for each complete resource set.
Legacy managed/imported originals are only reuse candidates: the server freshly copies and hashes
them into the immutable local version before issuing its retained receipt. Explicit permanent
consumers also protect matching legacy temporary copies from automatic expiry.

`POST /api/v2/uploads` admits a bounded foreground transfer. `HEAD /api/v2/uploads/<id>` returns
`Upload-Offset`, `Upload-Length`, and `Upload-Max-Chunk`, without a body. `PATCH` requires the integer
`Upload-Offset` and `Content-Type: application/offset+octet-stream`; successful durable writes return
204 and the new offset. A conflicting offset requires HEAD, not blind appending. Complete with
`POST /api/v2/uploads/<id>/complete`; size, SHA-256, durable publication and catalog commitment precede
a retained receipt. Failed/unfinished publication keeps a recovery journal. Storage pressure is
explicit backpressure, never permission to delete originals.

The phone yields its upload slot after four chunks. Further quanta re-admit the same immutable
transfer intent and query the durable offset again; an execution state from the previous quantum
is not a new admission. Failed local intent admission releases its working-space reservation.

Use `/api/v2/changes?after=<cursor>&epoch=<historyEpoch>` or `/api/v2/snapshot` to reconcile results.
Snapshot continuation tokens are opaque, expiring, and bound to the authenticated device.
Immutable `/api/v2/derivatives/<generation>/resources/<role>` downloads provide exact lengths,
strong ETags, and single Range/If-Range support. Version-qualified source resources are available at
`/api/v2/assets/<asset>/versions/<manifest>/resources/<role>?request_id=<request>`; Linux Live Photo
motion still requires AVFoundation on the phone, never FFmpeg pairing. Delivery acknowledgement IDs
are client-generated UUIDs posted to `/api/v2/deliveries/<id>/ack`; acknowledgements only account for
delivery. Fresh `/api/v2/assets/<asset>/versions/<manifest>/verify` accepts `BackupAPI.Version` and
requires that device's permanent local claim. No endpoint falls back to mutable v1 proof.

With a Linux server the receipt delegates Live Photo motion (`device_compresses: ["paired_video"]`).
The iPhone re-encodes the retained original motion with AVFoundation (`LivePhotoMotionCompressor`),
reserving the motion's size four times over for the encode, checks the pair with `PHLivePhoto`,
and imports it only after the server's retained-original proof; the saved pair is verified before
any original can be offered for removal. Motion that does not get smaller is kept byte-identical.
A hard bound on total working space is planned for a later release. Native/background transfers
remain unavailable.

Immich remains read-only. Its independently scheduled acquisition downloads and checks every
expected original resource by positive size and SHA-256, using SHA-1/search only to locate it.
Edited/RAW/auxiliary-resource manifests are rejected explicitly. No upload protocol is advertised
in Immich mode, and no permanent duplicate original is added to the managed originals root.
Temporary checked processing inputs are bounded and reclaimed after their worker references end.

Immich capabilities negotiate `external_verification: full_resource_scrub`. Every strengthened
external proof freshly downloads **all** expected resources again, checks sizes/SHA-256 and live
association/availability, and returns `retention: external`, never permanent-local retention.
Version-qualified external original downloads also verify complete requested bytes before serving
a range. A scrub establishes observed identity/availability, not immunity to a later Immich
operator change. The phone must negotiate this contract, verify its current complete local
resources and imported compact, and bound proof age before iOS confirmation; mode alone is not proof.

Cloud Copies includes retained immutable v2 manifests. OneDrive names contain the full manifest,
role and resource hash; retries deduplicate verified objects and conflicts never overwrite older
originals. Generation-fenced jobs retry durable transfers under shared connector capacity.
`GET /api/v2/backup-requests/<id>/copies` returns owner-bound per-connector `ConnectorCounts`;
the normal connector counts include v1 and v2. Destination changes fence old completions.
Cloud copies and their status never substitute for local retention or fresh external byte proof.

An optional owner-configured `HOMESPUN_WAKE_RELAY_URL` (HTTPS, default absent) enables a content-free
wake sender. Not used by Homespun 1.1.0: leave `HOMESPUN_WAKE_RELAY_URL` unset.
This does not deploy or advertise a functioning relay. After the phone opts in and
activates its relay route, `POST /api/v2/wake/enrollment` accepts only `WakeRelayAPI.Sender`
(`route_id`, `generation_id`, canonical 32-byte `token`) for that authenticated device.
Without an owner endpoint it returns `wake_unavailable` and stores nothing. It returns an ETag
containing the enrolled generation. `DELETE /api/v2/wake/enrollment` sends that generation as
`If-Match`; a stale retirement cannot erase a newer route. Unpair/revoke disables the route.
No APNs token, provider key or client-supplied relay URL is accepted.

The durable outbox coalesces hints, retries the same content-free nonce after lost responses,
and preserves newer changes for a new nonce. Route/generation/lease fences reject stale completions.
Acceptance is not device delivery/execution. Sends are throttled to about three per hour per
consumer; a gone route is retired without touching work or retention. The service joins sends and
shuts down its HTTPS client explicitly. Authenticated changes/snapshots remain correct without push.

After an **offline, consistent catalog restore**, run `homespun-server resync-history` before
restarting. It preserves the server ID and originals but advances the history epoch and requires
client snapshots. Silent database replacement within one epoch is unsupported. Older binaries
refuse the newer schema; a downgrade must preserve newer files and use a deliberate recovery path.

Unreleased preview catalogs containing descriptor generation zero are unsupported. Requests, lookups
and result feeds fail closed with `unsupported_preview_history`; neither retries nor `resync-history`
repair these immutable identities. Preserve the entire old data directory and originals. Only for
disposable preview/test data, stop the server, choose a new empty `--data` directory with a separate
originals root, then re-pair and reselect originals that remain available. Never delete the old
originals to work around this error. No automatic migration or repair command is provided.

Conservative defaults are one photo slot, one video slot, two verification slots, two bounded
chunk writers, one connector slot, 128 active upload records, a 64 GiB staging reservation limit
and a 1 GiB free-space floor.
`HOMESPUN_PHOTO_WORKERS`/`HOMESPUN_VIDEO_WORKERS` allow 1–2 shared slots;
`HOMESPUN_MAX_STAGING_BYTES` and `HOMESPUN_MIN_FREE_BYTES` configure storage limits.
FFmpeg/x265 and libvips thread use is bounded; FFmpeg limits individual allocations, not total
process RSS. FFmpeg output is bounded to twice its source while deciding whether to keep the
original, and processing reserves space for the input snapshot plus working output. An encoder
may run for hours while its frame/media-time counter advances; only
30 minutes without progress triggers the stalled-work watchdog. No energy improvement is claimed.

### Run on a NAS with Docker

The image `ghcr.io/akshob/homespun-server` runs Homespun Server on a NAS (Synology, QNAP,
UGREEN, TrueNAS, Unraid, Asustor, TerraMaster) or any Linux computer with Docker, on amd64 and
arm64. It holds everything the server needs: libvips, ffmpeg with x265, and the Bonjour tools.
As with any Linux server, the iPhone compresses Live Photo motion.

1. As your own user (on Synology, in File Station), make a folder for Homespun with a `data`
   folder in it, for example `docker/homespun/data`, and a folder for originals on your photos
   share, for example `photo/Homespun`.
2. Put [`deploy/compose.yaml`](deploy/compose.yaml) in the Homespun folder. In it, set the
   originals folder, the name the app shows, and `user` to your user's IDs (PUID:PGID), so
   Homespun can write to both folders. `id` in an SSH session on the NAS shows them; on Synology
   the first user is usually `1026:100`. The container never runs as root.
3. Start it: `docker compose up -d` in the Homespun folder. On Synology: Container Manager ›
   Project › Create, pick the Homespun folder, and use its compose.yaml.
4. Pair the app: `docker exec homespun homespun-server pair` prints a QR code, a link, and a
   code. (In Container Manager, open the container's Terminal tab and run
   `homespun-server pair`.) Other commands work the same way, for example
   `docker exec homespun homespun-server devices`.

Originals go in `/originals` in the container (a folder per phone, by month, as above); the
catalog, compact copies and encryption key (`/data/tls`) go in `/data`. Back up both. The folders must exist before the
container starts: with compose.yaml, Docker stops with an error instead of making an empty folder,
so a share that isn't mounted is never silently replaced. To move originals later from the app, first add the new
place to `volumes` under `/mnt` (for example `/volume2/photos:/mnt/photos`); the app then offers
it. The server sees only the folders the container is given.

The container uses the NAS's own network (`network_mode: host`), so the pairing link carries the
NAS's address and the app finds the server with Bonjour. Bonjour goes through the NAS's
avahi-daemon over D-Bus (the `/var/run/dbus` volume); the self-check in the app says when that is
missing. D-Bus answers only users the NAS knows, which is one more reason to use your own user's
IDs. On computers with AppArmor (Ubuntu), Docker's default profile blocks D-Bus, so compose.yaml
turns it off for this container (`apparmor:unconfined`). Without Bonjour, or on a bridge network,
enter the address and code in the app instead; on a bridge network, also publish port 8787 and set
`HOMESPUN_PUBLIC_URL` to the NAS's address.

The image sets `HOMESPUN_DATA=/data`, `HOMESPUN_ORIGINALS=/originals`, `HOMESPUN_HOST=0.0.0.0`,
and `HOMESPUN_HARDWARE_KIND=container`. Other settings go under `environment`: `HOMESPUN_NAME`,
`HOMESPUN_PORT`, `HOMESPUN_PUBLIC_URL`, `HOMESPUN_HARDWARE` (the model the app shows, for example
`Synology DS923+`), and `HOMESPUN_COMMAND` if the container isn't named `homespun` (the app shows
it in commands, `docker exec homespun homespun-server` by default). Docker checks
`GET /api/v1/health` over HTTPS every 30 seconds.

To update, pull the new image and recreate the container; the data stays in the folders:

```bash
docker compose pull && docker compose up -d
```

In Container Manager: stop the project, choose Action › Build (it pulls the new image), then
start it. `latest` follows the main branch; version tags like `0.2.0` follow releases.

To build the image yourself (`docker buildx` builds both architectures; pushing needs a
registry you can write to):

```bash
docker build -t homespun-server .
docker buildx build --platform linux/amd64,linux/arm64 -t ghcr.io/<you>/homespun-server --push .
```

### Reaching the server through a proxy or Tailscale

For a proxy with a publicly trusted certificate, set `HOMESPUN_PUBLIC_URL=https://photos.example.com`.
The app uses system trust for that name.
When the proxy terminates TLS with a different key, pair using its address and a pairing code,
not the backend's fingerprint link or six-digit key comparison.
Homespun's backend still accepts only HTTPS:

```caddyfile
photos.example.com {
    reverse_proxy https://127.0.0.1:8787 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
```

For nginx, use `proxy_pass https://127.0.0.1:8787; proxy_ssl_verify off;` in the proxy location.
Keep that unverified backend hop on loopback or another trusted private path, never across an
untrusted network. With Tailscale: `tailscale serve --bg https+insecure://127.0.0.1:8787`.
Direct LAN or Tailscale IPs and `.local` names use key pinning. For a qualified name pointing
straight at the self-signed server, iOS's transport rules cannot be loosened by the pin check:
use its IP address, `.local` name, or a proxy with a trusted certificate instead.

Custom server binaries calling `ServerCommand.run(connectors:)` need only update their Homespun
dependency. A custom `Application(router: server.router(), ...)` must switch to `server.application()`
so it uses the TLS listener. Route-only tests can use `server.testRouter()` and the challenge/reveal
protocols; scripts and health checks must use HTTPS.

### Pairing the same iPhone again

The app keeps a random installation ID and the last device name the server confirmed in the
device-only, non-synced Keychain. They survive Unpair and reinstalling the app, but not erasing
the phone. Pairing sends that ID and the remembered name over the authenticated TLS flow.
After owner approval, an active record with the same hashed install ID is reused: its device
ID, name, originals folder, assets and events stay put; a new token replaces the old token
hash and an event records that it paired again. The install ID is only a matching key, never
an authentication proof.

Unpair attempts to revoke the device when the server is reachable. Explicitly revoked records
are never reclaimed; a subsequent pairing creates a new active record with the remembered name.
An offline Unpair leaves the old active record available to reclaim. Existing catalog rows
without an install ID are not guessed by name and retain the old behavior.

This adds a nullable, indexed `devices.install_id` column containing a hash. Back up `homespun.db*`
before updating. Rolling back to a binary with the older schema requires restoring that catalog
backup too; keep `tls/`, saved server settings and the originals backed up separately as usual.

### Cloud copies (connectors)

The server can also copy each original somewhere else once it has stored and checked it (for
items waiting for their compact copy, once it's made, so cleaned-up photos never go out), as
an extra backup (Cloud Copies is hidden in the 1.0.0 app). Copies never count toward removing an
original from the iPhone; only the server's own verified copy does. Each copy is checked
where the service allows it, and a full or offline destination is retried later without
holding up compact copies.

- **OneDrive**: sign in from the app with a code. Homespun asks only for its own app folder
  (`Apps/Homespun` in OneDrive) and checks every upload against OneDrive's QuickXorHash.
  Homespun Server includes its public Microsoft application ID. A custom build can override it
  with `HOMESPUN_ONEDRIVE_CLIENT_ID` using a public-client registration with device code flow and
  delegated `Files.ReadWrite.AppFolder`, `User.Read`, `offline_access`. No client secret is needed.
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

Stop the serving process before a mutating import, including in-place linking. Imports require
exclusive catalog ownership and refuse to race a live service or an unfinished originals move.
`--dry-run` remains read-only and can run alongside the service.

Running the import again is safe (finished items are skipped).
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

Then, in the app, open Server › Existing Library › Find Compact Copies. It hashes the photos and
videos Homespun doesn't know yet. Hash lookup (`POST /api/v1/copies/lookup`) supplies hints only.
In 1.1, `POST /api/v2/copies/resolve` resolves the complete compact resource set to one exact
original manifest; `/copies/adopt` admits an idempotent, device-owned permanent request using
the normal immutable-original adoption path. The server freshly copies and checks legacy
originals when needed; in-place imports remain untouched. Existing immutable objects are reused.
Only hashes, file roles and sizes leave the phone, not media or its local file names.
After a fresh versioned server byte proof and another full local compact check, Copy Finder
writes the canonical verified mapping and adds the copy to the Homespun album, without importing
or uploading it again. An original here becomes ready only if **all** its resources match too;
Free Up Space still performs its separate fresh proof and iOS confirmation.

A Live Photo whose motion the iPhone compressed (Linux server) cannot yet be re-linked by
Find Compact Copies; its original stays retained and nothing is removed.

This establishes an equivalent backup on the **current authenticated server**, not where an
old copy was first made. Unknown historical provenance remains unknown. Partial or ambiguous
resource sets, changed originals, older servers and Immich-only sources stay untrusted and show
recovery guidance; keep the items, reconnect the original archive and run again after updating
the server if necessary. Neither a legacy match nor a remembered URL authorizes deletion.

## Analytics and problem reports

The app asks once, during setup (after pairing, before Photos access), whether to share
anonymous analytics; it can be changed in Server › Share Analytics, which can also delete what
was shared. Sharing sends rounded counts and short codes (setup steps, pairing, the server's kind
and version, run sizes, features, purchase views and outcomes, error codes) and MetricKit's metrics and crash/hang diagnostics;
never photos, file names, places, or the server's name or address. Each opt-in gets a new random
install ID. Report a Problem (Server › Help and About) sends what the person writes, an optional
email, and diagnostics they can read first; it works without sharing analytics. Reports with an email
never include the analytics install ID. Delete Shared Data deletes reports linked to an install;
reports with an email can be deleted by emailing support@homespun.photos with the report number. If Homespun quit
while on screen, the next launch offers a report once (iOS shows nothing itself when an app
crashes). Debug builds send only to an endpoint given with `-telemetryEndpoint <url>`.

Everything goes to `services/telemetry`, a Cloudflare Worker (D1, R2, Email Routing for reports);
see its README for the API, tests, deployment and queries. `PrivacyInfo.xcprivacy` declares the
collected data. App Store Connect › App Privacy answers to match: Data Not Linked to You: Product
Interaction, Device ID, Performance Data and Purchase History (Analytics); Data Linked to You: Email
Address and Customer Support (App Functionality), Crash Data and Other Diagnostic Data (Analytics and
App Functionality), because reports can include an email; no tracking. The in-app Privacy Policy links
in Help and About, Share Analytics, setup, and Report a Problem lead to `https://homespun.photos/privacy`.

## Website

`site/` holds the static site for [homespun.photos](https://homespun.photos): plain HTML
and CSS, no scripts or build step. It is hosted on Cloudflare Pages (project `homespun`).
CI checks every change to it (`ci/site-check.py`: titles, links and anchors, nothing the
Content-Security-Policy blocks; html-validate: valid HTML) and publishes `main` to
homespun.photos (the `website` environment holds the Pages token). By hand, with a Pages-scoped
API token and the account ID in the environment:

```bash
python3 ci/site-check.py site && npx wrangler@4 pages deploy site --project-name homespun --branch main
```

## Roadmap

1. Background uploads and downloads (URLSession background sessions), album membership.
2. Done: HTTPS with a pinned server key, without a certificate service or a homespun.photos name.
3. Demo mode, TestFlight, then the App Store.

## License

- `HomespunCore`, `HomespunMedia`, the iOS app, and tests: [Apache-2.0](LICENSE).
- `homespun-server` (`Sources/HomespunServer`): [AGPL-3.0-only](Sources/HomespunServer/LICENSE).
  If you run a modified server for others over a network, you must offer them its source.

Each source file carries an SPDX license identifier. The name "Homespun" and the
app icon are not licensed under either license; forks must use a different name
and icon.
