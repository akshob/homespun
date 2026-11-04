# Roundtrip

Keep full-quality originals on your own server and compact copies in Apple Photos.

Roundtrip is the iOS companion for [PhotoRelay](https://github.com/akshob/photo-relay):
you pick photos and videos, the originals are stored and verified on your server,
compact copies come back to Apple Photos, and (optionally) the originals are removed
from the iPhone only after the server proves it has an identical copy.

## Modes

1. **On-phone:** the app compresses with Apple's encoders. No server needed for
   compression; originals stay wherever they already are.
2. **Self-hosted:** Roundtrip Server (Linux, Docker) stores originals and compresses
   with x265, producing the smallest files.
3. **Immich add-on:** the server reads originals from an existing Immich server by API
   key. The app saves compact copies to a "Roundtrip" album that you exclude from
   Immich backup, so they are not re-uploaded or shown in the Immich timeline.

## Layout

| Target | Platforms | Purpose |
|---|---|---|
| `RoundtripCore` | iOS, macOS, Linux | Compression profile, SHA-256 fingerprints, download manifest, deletion gate |
| `RoundtripMedia` | iOS, macOS, Linux | Media backends. Linux: x265 via the `ffmpeg` tool. Apple (planned): ImageIO, AVFoundation |
| `roundtrip-server` | Linux, macOS | Hummingbird HTTP API (`GET /api/v1/health` so far) |
| iOS app | iOS | Planned: SwiftUI + PhotoKit (needs Xcode on a Mac) |

Live Photo motion is compressed only with AVFoundation (on the phone or a Mac).
FFmpeg breaks the links between the still and its motion, so iOS no longer treats
the pair as a Live Photo.

## Safety rules

- An original's SHA-256 is its identity.
- The app may delete an original only if the server's copy matches its size and
  SHA-256, and the compact copy was imported and verified (`DeletionGate`). Check
  again at deletion time.
- Deletion always goes through iOS's own confirmation; items stay in Recently
  Deleted. Roundtrip never empties Recently Deleted.
- Outputs are written to a temporary name, verified (dimensions, audio tracks,
  duration within 0.5 s or 1%, full decode), then published. A video that does not
  get smaller keeps the original.

## Build and test

Requires Swift 6. On Linux the media tests need `ffmpeg` with libx265.

```bash
swift build
swift test
ROUNDTRIP_HOST=127.0.0.1 ROUNDTRIP_PORT=8787 swift run roundtrip-server
```

If git refuses SwiftPM's dependency cache (`safe.bareRepository is 'explicit'`),
override it for the command only:

```bash
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build
```

## Roadmap

1. Linux photo backend (libheif + libvips + exiv2), matching PhotoRelay's 2048 px output.
2. Server catalog (SQLite), resumable verified uploads, job queue, download manifests.
3. iOS app: pick, upload, on-phone compression (ImageIO/AVFoundation), PhotoKit import
   with date/location/favorite/albums, gated deletion.
4. Immich add-on, Docker image, demo mode, then TestFlight and the App Store.
