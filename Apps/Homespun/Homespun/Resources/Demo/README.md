# The demo's videos and Live Photo

SPDX-License-Identifier: Apache-2.0

Drawn by `Apps/Homespun/scripts/demo-media.sh` (`demo-media.swift` with the app's
`Features/Demo/DemoArt.swift`; no photographs, no third-party media).

The demo's photos, screenshot and grid pictures aren't here: the app draws them on the iPhone
with the same `DemoArt.swift` when the demo starts (`DemoMedia.swift`), and writes `samples.json`
then. `compact/` holds the compact copies the pretend server sends back for the videos and the
Live Photo (it makes the photos' own by shrinking them). A unit test
(`DemoMediaTests.bundledMediaFitsTheBudget`) keeps this folder at 5 MB or less.
