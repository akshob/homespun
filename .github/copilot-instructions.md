# Homespun repository instructions

Homespun keeps full-quality photo and video originals on the user's own server and
compact copies in Apple Photos. It has an iPhone app, a self-hosted server, and an
optional Immich add-on. Read `README.md` first. If `.copilot/handoff.md` exists
locally, read it for current status, machines, and next steps. It is git-ignored
and may not exist in other checkouts.

## Layout and languages

- One Swift package (Swift 6, swift-testing):
  - `HomespunCore`: shared by the app and server. No platform media APIs here.
  - `HomespunMedia`: media backends. Linux uses open-source tools and libraries;
    Apple platforms use ImageIO and AVFoundation.
  - `HomespunServerKit` (AGPL, library) and `homespun-server` (thin CLI): Hummingbird 2,
    system SQLite through `CSQLite`, AsyncHTTPClient for Immich. API types shared with the
    app live in `HomespunCore/ServerAPI.swift` (snake_case JSON; use `ServerAPI.encoder`).
    Coding keys with acronyms must survive snake_case both ways (`videoCrf`, `assetId`).
- iOS app: `Apps/Homespun`, generated with XcodeGen (`project.yml`). Do not commit
  the generated `.xcodeproj` or signing settings. Bundle ID: `photos.homespun.app`
  (Release); Debug uses `photos.homespun.app.dev` so free Personal Teams never register
  the App Store ID. `Signing.xcconfig` includes the git-ignored `Local.xcconfig`, which
  holds `DEVELOPMENT_TEAM`. Never put a team ID in `project.yml`.
- App sources (`Apps/Homespun/Homespun`) are grouped by layer; XcodeGen picks up any folder:
  - `App/`: entry point, `AppModel` (composition root), root and tab shell, settings, journey/tips.
  - `Features/<Library|Item|Activity|Server|Setup|Premium|Feedback|Demo>/`: screens and their controllers.
    `Demo/` is Try the Demo: its own `AppModel` on sample photos (`DemoLibrary`, media drawn on the iPhone
    by `DemoArt`/`DemoMedia`, plus the videos and Live Photo in `Resources/Demo`)
    and an in-app pretend server (`DemoServer`, reached through `ServerClient` by `DemoURLProtocol`).
  - `Backup/`: the engine (job queue, server pipeline, ledger, schedule, automatic mode, background runs,
    history, original removal, copy finder). No views.
  - `Services/`: PhotoKit, server client and discovery, Keychain, telemetry, diagnostics, performance monitor.
  - `DesignSystem/`: theme, shared controls, adaptive layout (grid columns, `SplitNavigation`).
  - `Support/` (Objective-C bridging) and `Resources/` (app icon, privacy manifest, entitlements).
- Next to it: `Shared/` (the widgets' status, `StatusSnapshot`, and its words: compiled into the app, the
  widgets and the watch app), `Widgets/` (the WidgetKit widget, one source for the iPhone's
  `HomespunWidgets` and the watch's `HomespunWatchWidgets`), `HomespunWatch/` (the watch app) and
  `HomespunWidgetTests/` (every widget size drawn). The widgets never use the network; they show what the
  app last wrote into the App Group `group.$(HOMESPUN_BUNDLE_ID)`. Widget and watch targets get bundle IDs
  under the app's (`.widgets`, `.watchkitapp`, `.watchkitapp.widgets`) and the same version.
- Everything is Swift. Do not add Python, Node, or shell pipelines to the product.
- `site/` is the homespun.photos website: static HTML and CSS only (no JavaScript, no
  third-party assets or analytics; `_headers` sets a strict CSP). The privacy policy there
  must match what the app actually does; update it when data handling changes. CI checks it
  (`ci/site-check.py`, html-validate) and publishes `main` to homespun.photos; don't deploy by hand.
- Code that uses `Foundation.Process` must be wrapped in `#if os(Linux) || os(macOS)`,
  because iOS has no `Process`.
- Apple backends live in `Sources/HomespunMedia/Apple`, each file wrapped in
  `#if canImport(AVFoundation)`, `ImageIO`, or `Photos` so Linux builds skip them.
  Shared result types and publish helpers (`MediaFiles`) are cross-platform.
- Every source file starts with an SPDX identifier: `Apache-2.0` everywhere except
  `Sources/HomespunServer`, `Sources/HomespunServerKit`, `Sources/CSQLite`, and the server
  tests, which are `AGPL-3.0-only`.
- libvips is called through the small C shim `CHomespunVips` (its API is variadic). libvips
  drops Apple maker notes, so the Linux backend copies the source EXIF block verbatim and
  patches only Orientation and pixel size (`ExifEditor`).
- The name "Homespun" and the app icon are reserved and not covered by the licenses.

## Media rules (learned from a 37,000-item real library)

- Default profile: photos fit within 2048 px on the long edge. Ordinary videos fit
  within 1280x720 as HEVC (x265 CRF 28 on servers, `hvc1` tag) with AAC 96k.
  Never upscale. Video dimensions must be even.
- Live Photo motion must be re-encoded with AVFoundation, which keeps the
  `mebx`/ContentDescribes timed-metadata links. FFmpeg breaks Live Photo pairing.
  Keep the encoded size and clean aperture, or the motion looks zoomed in.
  Validate pairs with `PHLivePhoto`.
- Hardware HEVC (VideoToolbox) files were about 2-3x larger than x265 at similar
  quality (VMAF). Use x265 on servers; the phone encodes only Live Photo motion (Linux server).
- Map only audio streams the local decoder can decode. Apple spatial audio (APAC)
  is skipped in derivatives and kept in the original.
- Verify before publishing: dimensions within profile, same audio track count,
  video-stream and container durations each within 0.5 s or 1%, and a full decode.
  Write to a temporary name, then publish atomically.
- If a derivative is not smaller than its source, keep the original byte-identical.
- Undecodable or truncated inputs are flagged, never marked complete and never
  silently skipped. ImageIO decodes truncated JPEGs without error (grey fill), so
  JPEGs are checked structurally (`JPEGIntegrity`) before decoding.
- Preserve capture date with its offset, GPS, orientation, camera metadata, and
  Apple content identifiers. Apple Photos and PhotoSync order items by embedded
  capture date; undated media (WhatsApp, shared items) shows up on import day.
- Hold HDR other than HLG (PQ, Dolby Vision-only) and >60 fps video unchanged
  until a conversion is validated. HLG becomes 10-bit HLG (main10).

## The demo (Try the Demo)

- Photos are read and changed only through `PhotoSource` (`PhotoKitSource` for Photos, `DemoLibrary` for
  the demo); the Library grid reads Photos itself (`LibraryModel`) unless it has an `ItemCatalog`. Views
  take the `LibraryModel` rather than its image manager (`Thumbnail`, `ThumbnailRow`/`ThumbnailLoader`), and
  the viewer's pages show `LibraryModel.item` (`any LibraryItem`). New PhotoKit calls go behind
  `PhotoSource`, so the demo never touches the person's library.
- The demo's model keeps its own settings (`photos.homespun.demo`), folder (`Homespun Demo`), token and
  records; it never writes the person's settings, Keychain, TipKit tips or analytics (`Telemetry.paused`).
  It shares `StatusPublisher` only to show demo facts in widgets and on the watch when no real server is
  paired; leaving clears them, and a paired person's real status is never replaced. The demo
  never asks iOS for a permission, and pairs only with its pretend server. Leave the Demo deletes it all.
- The demo changes nothing for real: its deletions ask in-app, say so, and remove only from the demo.
- `DemoArt.swift` is the only drawing code, shared with `scripts/demo-media.swift`; keep it free of UIKit
  and HomespunCore and deterministic (seeded): an original's SHA-256 is its identity, and a resumed demo
  checks its drawn files against `media.json`. Drawn media lives in `Homespun Demo Media` (deleted at
  launch, kept on leaving); demo state in `Homespun Demo` (deleted on leaving). `Resources/Demo` stays
  ≤ 5 MB (`DemoMediaTests`).

## Safety invariants (never weaken)

- An original's SHA-256 is its identity.
- The app may ask iOS to delete an original only if the server's stored copy
  matches its size and SHA-256 and the compact copy was imported and verified
  (`DeletionGate`). Re-evaluate at deletion time; never trust a stored status alone.
- The app always works through a paired server (the on-phone mode was removed);
  an item with no server copy can never be removed.
- Deletion always goes through the iOS confirmation. Items stay in Recently
  Deleted. Never empty Recently Deleted.
- Zero-byte originals and hash mismatches block deletion.
- Copy, verify, approve, and delete are separate steps. Operations are idempotent
  and restart-safe.
- The server stores originals only in configured roots. Validate paths and never
  accept arbitrary paths or commands from clients.
- Immich add-on: never modify or delete Immich assets. The API key needs only `asset.read`
  and `asset.download` (no upload). Originals found in Immich are downloaded and checked
  byte for byte (SHA-256 and size) before they are trusted. Compact copies go to a
  "Homespun" album that the user excludes from Immich backup.
- The server writes only under its data directory. Client file names pass through
  `Storage.sanitized`; catalog paths are resolved with `Storage.resolve`.

## Validation runs in CI (ci/README.md)

- Validate changes with GitHub Actions, not by hand. Pushing a branch runs nothing. Open a draft
  pull request (build and unit tests), mark it ready for the quick checks (`pr.yml`: a short iPhone
  run and a short iPhone Duo run), merge when `PR / Result` passes; the extended suite runs after
  the merge (`ci.yml`), everything nightly (`nightly.yml`). For risky work before a pull request:
  `gh workflow run ci.yml --ref <branch> -f ui=quick|full`. Read only the run's summary and
  failures (`gh run watch`, `gh run view <id> --log-failed`, `gh run download` for screenshots).
  macOS machines are few (five at once): push in batches.
- Everything runs on GitHub's machines (the repository is public). Never attach a self-hosted
  runner to this repository; performance budgets run from a separate private repository. Test
  servers use their own data and ports, never a real server's (port 8787).
- A new UI test class goes into a run in `ci/lane.sh` (with a free port); a new run also goes into
  `FULL` in `ci/plan.py` (after merge) and the nightly list in `.github/workflows/nightly.yml`; only
  short, critical-path tests belong in `quick`/`quick-duo`. New test media goes into `ci/`.
- UI and unit jobs always upload `timing-<run>-<workflow id>` (7 days): phase TSVs, logs and
  result-bundle SQLite metadata. Read the summary's Timing table before changing CI waits or
  lane packing; use Actions step durations for checkout, brew and artifact transfer. Keep the
  `stamp`/`timed` boundaries in `ci/env.sh` and each segment accurate when editing CI scripts.

## Build and test

```bash
swift build && swift test        # Linux and macOS
# If git rejects SwiftPM's cache (safe.bareRepository is 'explicit'):
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build
cd Apps/Homespun && xcodegen generate   # macOS only
```

- Test with synthetic media generated by `ffmpeg -f lavfi`, ImageIO, or AVAssetWriter
  (`HomespunTestSupport`'s `Synthetic`) in temporary directories. Never use a real
  photo library or a connected phone in tests.
- App tests (`Apps/Homespun/HomespunTests`) touch PhotoKit, so run them only on a
  throwaway simulator created for the run, with access granted by
  `xcrun simctl privacy <id> grant photos photos.homespun.app.dev`, then delete it.
  Do not reuse other simulators on the machine. Test code cannot delete assets
  (iOS asks for confirmation).
- `ServerModeUITests` pairs with a running server and is skipped unless `xcodebuild test` gets
  `TEST_RUNNER_HOMESPUN_SERVER` and `TEST_RUNNER_HOMESPUN_PAIRING_CODE` (optionally
  `TEST_RUNNER_HOMESPUN_PICK`, `TEST_RUNNER_HOMESPUN_REMOVE=1`). Use a fresh simulator whose
  library holds only synthetic media, and a server with a test data directory.
- `ItemViewerUITests` takes the same two variables and runs in order on one simulator: `test1…`
  pairs and backs up the 2 newest, `test2…` frees one and compares it with its original
  downloaded from the server, `test3…` takes review screenshots (Debug builds launched with
  `-itemDemoState failed` or `kept` show those Details variants on items not backed up).
- Feed each AVAssetWriter input from its own task; one loop over several inputs can deadlock.
- `HomespunUITests` selects in the app's own library grid (`GridSteps.swift`: cells have
  identifier `asset` and the badge label as value) and reads item states from `status.<state>`
  in Activity. Server tests are numbered (`test1…` pairs, `test2…` reuses the pairing).
  Don't use SKTestSession in the hosted unit tests: the app process talks to the real App Store
  (purchases asked for an Apple Account sign-in). Test Premium logic with the `owned:` stand-in.
- Live Photo content identifiers in tests must be UUID strings: ImageIO stores Apple
  maker-note tag 17 as a fixed 36-byte field and pads shorter values.
- iOS simulator video encoders ignore requested bitrates; do not assert encoder-dependent
  sizes there.
- Run `swift test` on both Linux and macOS before pushing changes to shared code.
- CI, if added, must use GitHub-hosted runners. Never run pull-request code on a
  self-hosted machine that has access to photos or credentials.
