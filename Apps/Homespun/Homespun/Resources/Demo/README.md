# The demo's videos and Live Photo

SPDX-License-Identifier: Apache-2.0

Drawn by `Apps/Homespun/scripts/demo-media.sh` (`demo-media.swift` with the app's
`Features/Demo/DemoArt.swift`; no photographs, no third-party media).

The demo's photos, screenshot and grid pictures aren't here: the app draws them on the iPhone
with the same `DemoArt.swift` when the demo starts (`DemoMedia.swift`), and writes `samples.json`
then. `compact/` holds the compact copies the pretend server sends back for the videos and the
Live Photo (it makes the photos' own by shrinking them). A unit test
(`DemoMediaTests.bundledMediaFitsTheBudget`) keeps this folder at 5 MB or less.
# Reviewer photos

Ordinary demos draw their stills. An optional App Review code authorizes 16 private photos downloaded
through the telemetry Worker; none are bundled or committed. Their SHA-256 is checked before use,
thumbnails and compact copies are derived on the phone, and all downloads are wiped at cold launch.
The motion resources here remain unchanged. A failed download uses the complete drawn library.
