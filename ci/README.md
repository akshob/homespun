# Continuous integration

Every change is validated by GitHub Actions (`.github/workflows`), not by hand. Quick checks gate a
pull request; the extended suite runs after the merge; everything runs every night.

| Workflow | When | What |
|---|---|---|
| `pr.yml` | pull request to `main` | quick checks of what it changes (about 20–25 minutes): the server on Linux, the telemetry Worker, the website, the app's build and unit tests (PhotoKit ones included), and two short UI runs side by side: `quick` (iPhone: pair, back up, compare, Keep Original, free up, the viewer, Select All, rename) and `quick-duo` (iPhone Duo open in every pose). Watch, widget, shared-status or project changes also run `watch`. A draft gets the build and unit tests only. `PR / Result` sums it up; `main` requires it. |
| `ci.yml` | after a merge to `main` | the extended suite: what changed, with every UI run, one per machine: iPhone (`iphone`, `library`, `later`, `copies`, `onboarding`, `telemetry`, `resume`) and iPhone Duo (`duo-cover`, `duo-grid`, `duo-open`), Try the Demo on both (`demo`, no server), and the server's package tests on macOS; the website goes live when it changed (environment `website`). One run at a time; only the newest waiting merge runs next. A failure opens or updates the issue "main is failing"; a pass closes it. |
| `ci.yml` | Run workflow (any branch) | everything with UI runs `none`, `quick` or `full`; an individual UI run builds the app, runs its unit tests and that existing lane only; `copies` also checks both server platforms; `package` runs only the macOS package job |
| `nightly.yml` | every night | everything on `main`, plus long runs (`large`: 3,000 photos). Failures: the issue "nightly is failing". |
| `testflight.yml` | on demand, by the owner, who approves each run | only for a commit that passed the extended suite (`release-guard.py`); archive, sign in Apple's cloud, upload, wait until the build is ready; the symbols stay as the run's `dsyms-<build>` artifact |
| `docker.yml` | `main` when the server changes, and every version tag | the server's Docker image: `main` from main; `X.Y.Z`, `X.Y` and (newest release only) `latest` from a `vX.Y.Z` tag; pre-releases publish only their full version |

Pushing a branch runs nothing: open a draft pull request for the build and unit tests, mark it ready
for the quick checks, or use Run workflow.

Keeping UI runs reliable on shared cloud machines:
- A failing test runs once more in place (Xcode's `-retry-tests-on-failure`); one that passes then
  is named as flaky in the summary, and a test that fails twice still fails the run.
- When the simulator can't start or reach the test runner (no test ran), it's rebooted and the run
  tried once more.
- Each run's test server must be its own: the port must be free first, and the server stopped and
  waited for at the end.
- A known failure is listed in `quarantine.txt` with its issue: it's skipped and the summary says
  so, so the suite stays meaningful while the fix is made. The pull request that fixes it removes
  the line. `suite.yml` holds the jobs all of them share;
`ci/plan.py` decides what a run needs from the files it changes (design files and Markdown alone run
nothing; the website alone runs only its checks), because GitHub gives this account five macOS
machines at once.

All of it runs on GitHub's own machines, free for a public repository: Linux (`ubuntu-24.04`, the
server in the `swift:6.3-noble` container) and macOS (`xcode-27`: Xcode 27.2 with the iOS 27.2
simulators for iPhone 18 Pro and iPhone Duo). The macOS build job builds once and passes the app,
its tests and the release server to the other jobs as an archive (`build`). Every job starts on a
fresh machine. Pull requests from forks run after the owner approves them and never see secrets.

Test jobs unpack the archive and run its **`.xctestrun`**, not a project or scheme, so they do
not regenerate the project, resolve SwiftPM or clone packages. A missing manifest fails CI;
local Macs with older builds keep the project-based fallback in `test_without_building`.
Test selectors, per-test retries and `TEST_RUNNER_*` variables pass through unchanged. Server
flows fail if their log reports a skip for missing runner configuration rather than silently
passing without coverage.

Only the app build and `watch` jobs need XcodeGen. They share the Xcode package checkout cache
(`$CI_STATE/spm`, `xcode-spm-<Package.resolved hash>` with a prefix restore). Homebrew uses its
normal install path; the optional download cache is deferred. The watch job still builds
its own watchOS test bundle, then runs its own `.xctestrun` without resolving the graph a
second time.

The extended `oldserver` run (port 8804, never in the quick PR lanes) uses the immutable
`b35fc1901551ea1b01807a26f6a73cbbf68d8058` server. The build job checks out that commit separately,
caches its release binary by commit and macOS/Xcode image, and includes it in the build archive.
`OldServerUITests` seeds three real v1 backups with a Debug-only use of the retained 1.0 compactor,
checks badges and the update alert, frees/restores through iOS confirmation, then asks the host
watcher to restart the current server on the same data folder and port. It checks unchanged
legacy display/actions and new v2 admission without duplicate grid items. Both servers use
the existing key-pinned HTTPS readiness probe and are stopped before the disposable data and
simulator are removed. The nightly run list includes this lane; its remotely disabled state
is not changed or enabled by this compatibility work.

Performance budgets (`perf.sh`) need a Mac with a large iPhone Duo library (`setup-perf-sim.sh`,
35,000 photos) and steady timings, which shared cloud machines don't give; the owner runs them
nightly on a Mac of their own, from a separate private repository, so no self-hosted runner is ever
attached to this public one.

The iPhone demo run also checks app-side redraw counters (`-perfMonitor YES`): eight backups and Select All must not
reload the grid, blank unchanged pictures, or reevaluate the root per item. The filtered variant
checks incremental removals. `grid.visibleImageClears` uses the collection view's display lifecycle:
it must stay zero for unchanged visible pictures. The original `grid.imageClears` total is still
reported and bounded by thumbnail requests; clearing a recycled, not-yet-displayed cell is not
visible flicker. Configuration, thumbnail-request and root-render budgets are unchanged.
`perf.sh` backs up twenty items against its own disposable HTTPS
server (port 18808) and a disposable clone of the synthetic library: zero frames over 50 ms,
hitch time ≤ 5 ms/s, `GridApply` p95 ≤ 2 ms,
and at most one `BuildState` per finished item. These counters and timings appear in `perf.monitor`.

## The scripts (`ci/`)

All of them work on any Mac with Xcode 27.2, XcodeGen, ffmpeg and the iPhone Duo simulator runtime
(each picks the newest runtime installed for the device):

| Script | Does |
|---|---|
| `build.sh` | typechecks `scripts/demo-media.swift` with `DemoArt.swift`, then release server + `build-for-testing` into `~/ci/dd/<commit>` (once per commit; later jobs reuse it); `generate-project.sh --testing` embeds the retained widgets and Watch app for tests only (the shipping generator omits them in 1.0.0) |
| `unit.sh` | app unit tests on a fresh iPhone simulator with Photos access, and the widgets' (`HomespunWidgetTests`, every size drawn) |
| `watch.sh` | separate watchOS build and timed Crown/swipe regression on a fresh Apple Watch simulator (fresh, stale and arriving status, each crossing a minute boundary); no server or paired iPhone; downloads the watchOS runtime if missing |
| `presim.sh <device type>` | queue the first simulator's boot in the background, overlapping cache/artifact setup; disabled when `SIM_SLOTS_DIR` is set |
| `ui.sh <name> <device> <tests> <port> [open]` | UI tests on a fresh simulator against a temporary server (`EXTRA=`, `DATED=`, `DUO_POSES=1`, `STUB_PORT=`; `SERVERLESS=1`: no server and no Photos access, for the demo) |
| `dated-photos.swift` | small synthetic photos taken over the past months (EXIF dates) for `DATED=`: month headers, scrolling across months |
| `later.sh`, `copies.sh` | the compact-later and copy-finder end-to-end runs |
| `lane.sh <run\|group> ...` | UI runs by name (`quick`, `quick-duo`, `iphone`, `library`, …, `resume`, `large`) or group (`pr`, `iphone-all`, `duo-all`, `full`); `--first-device <run\|group>` selects the device for background boot; `RETRY_UI=1` retries a failed run once |
| `tools/duoctl/` | folds, turns and screenshots the iPhone Duo simulator |
| `perf.sh`, `setup-perf-sim.sh` | performance budgets; the performance simulator (once) |
| `tls-bench.zsh` | opt-in HTTPS upload measurement: a 1 GiB synthetic file, its own data folder and port 18787; never an installed server |
| `plan.py` | what a run needs (see above) |
| `release-guard.py <commit>` | whether a commit may go to TestFlight |
| `site-check.py`, `htmlvalidate.json` | the website's checks |
| `summary.py <results>` | the Markdown report each job adds to its summary (failures, flaky tests, known failures skipped) |
| `timing.py <results> <destination>` | collect phase stamps, logs and each result bundle's SQLite metadata, without its large image/video payloads |
| `quarantine.txt` | known UI test failures, each with its issue, skipped until fixed |

Results (`*.xcresult`, logs, Duo screenshots) are in `ci-results/`, uploaded when a job fails.
The app build also archives a `HomespunReleaseScope` test manifest. `unit.sh` runs it with features
off after the normal feature-enabled units, without resolving packages again. The quick iPhone lane
includes the release-scope UI regression; the full iPhone lane keeps all purchase/deep-link tests.
`WidgetGalleryUITests` remains opt-in for screenshots, using the `--testing` project and Debug opt-in.

`ui.sh` also exposes its isolated server's control file to UI tests. Writing `offline` or `online`
stops or restarts that test server; the matching `.ack` file confirms completion. The Library's
status-layout regression uses it at the newest end and mid-scroll, on iPhone and in the Duo poses.
Its Debug-only `-probeServerStatus` launch argument checks the real server every five seconds without
leaving the Library, so foregrounding or changing tabs cannot hide an inset jump.
Demo cancellation checks use Debug-only `-holdDemoPreparation`: the first preparation stays on its
loading page until cancelled, even if media finishes during an accessibility snapshot. A retry in
the same process runs normally, so these checks still verify media reuse and successful entry.

Test servers accept only HTTPS. Readiness probes derive an SPKI pin from that test server's
`tls/certificate.pem` and use `curl -k --pinnedpubkey`; port-occupancy checks are tokenless HTTPS
probes. Pairing links carry `fp=`, and address-and-code runs authenticate the server's code proof.
`ui.sh` gives tests `HOMESPUN_HOST_ACTION_FILE` (with the `TEST_RUNNER_` prefix when launching
Xcode); writing `rotate-key` there rotates only that run's temporary server key.
The address-recovery test uses `wrong-key-port` and `move-port`: it first refuses a separate-key
server, then restarts the original data/key on the lane's port plus 1000. A DEBUG-only candidate
list simulates Bonjour results in the simulator, but the TLS pin probe is real and cannot be
bypassed. One supervisor owns both the online/offline controls and these host actions, tracking
the current server PID, data and port so every restarted server is stopped.
The pairing-retention UI test renames this iPhone, unpairs and pairs again with a fresh code
from the `pairing-code` host action. It checks the confirmed name and one active Devices row.

The `resume` run (port 8802, its own iPhone and server) quits during a paced Debug upload, then
quits again before the server makes its compact copy. Both relaunches must continue without
reselecting anything. The test reads the server's request log to prove reuse of the upload and
its offset; `compact-settled` waits for the isolated catalog to report a ready result while the
app is closed. It is not in quick/PR runs and requires a fresh library, not an already completed backup.

Nightly's Linux server job opts into `HOMESPUN_PERF=1 swift test -c release --filter
tlsUploadThroughput`: 256 MiB through real registration, chunk upload, disk staging and hashing.
It compares a test-only plaintext listener with the production TLS builder; production never
serves plaintext. It reports both rates and checks the Linux budgets (TLS/plain ≥ 0.70 and TLS
≥ 200 MiB/s). macOS only reports the rates when explicitly opted in. `tls-bench.zsh` measures
HTTPS alone, since a production server has no plaintext comparison path; run it explicitly on
a test machine with a built release server, not against an installed service.

Every UI and unit job also uploads `timing-<run>-<workflow id>` for **7 days**, even when it
passes: `<segment>-timing.tsv`, logs and each `*.xcresult/database.sqlite3` (no `Data/`).
`stamp` in `env.sh` writes `⏱ <UTC time> <segment> <phase>` to the job log and tab-separated
`<segment> <phase> <epoch seconds>` to the TSV. Setup, bootstatus, initial Duo pose and its
15-second wait, each media generation/import, server readiness/pairing, test execution,
reboot retry, telemetry and cleanup have separate stamps. Duo pose logs include the UTC
request time and each tool call's start/end; these overlap test time, not simulator setup.
Pose requests carry a UUID. The host atomically claims each request and returns that UUID's explicit
success or failure; disappearance of a request file is not success. Late completions cannot acknowledge
or remove a newer request. `duoctl` waits through a temporarily inactive display within its existing
screen-switch deadline; a failed hinge or exhausted rotation retry is reported, not acknowledged.
The output filter is line-buffered, so test lines and first/last-test stamps arrive live.

The summary's **Timing** table gives seconds per segment: simulator setup, media, server,
xcodebuild preparation (start to first test), tests (first start to last result), teardown
(last result to xcodebuild exit, plus cleanup), and total. Retries contribute separately;
unavailable phases show `–` and incomplete totals show `≥`. The job's instrumented span
excludes checkout, brew and artifact transfer; use the Actions step durations for those.
Use the TSV for individual boot/media/pose measurements and the SQLite metadata for
per-test activity analysis. Lane membership, retries and quarantine are unchanged.

The `watch` run is in `full` and nightly too. Its 15-second per-step budget includes XCUITest's
idle wait: merely finding an element can pass even when SwiftUI is continuously relaying out.
Planner regression tests: `python3 -m unittest discover -s ci -p 'test_*.py'`.
After a test-only package fix, `gh workflow run ci.yml --ref <branch> -f ui=package` validates
only the macOS package job at the new head. This avoids repeating a full passing UI matrix:
GitHub's Re-run Job otherwise checks out the original, immutable commit. Package failures
keep their complete log in the `package-results-<run>` artifact.
After a lane-only fix, use its targeted input to validate it without repeating the full matrix.
GitHub's job rerun includes dependencies; jobs inside the reusable suite can rerun other suite jobs
too. Prefer the targeted workflow input (for example `ui=duo-open`) for a lane-only follow-up.

On a Mac shared by several jobs, set `SIM_SLOTS_DIR` to limit how many simulators boot at once
(see `env.sh`).

After tool installation, CI reserves `$CI_STATE/presim/<device>.pending`, then starts
`presim.sh`. Boot deliberately does not overlap brew: trials took **197–361 s** with a
download-cache hit and **459 s** without it, versus **31 s** in the contemporaneous build
job (no simulator). It overlaps the remaining package-cache/artifact setup instead.
It publishes the created, boot-requested UDID atomically; `new_simulator`
waits for publication, claims it once, renames it and waits on `bootstatus`. Later segments
still create and delete their own simulator. A failed preparation deletes its simulator
before allowing fresh creation; a stalled producer fails the segment instead of booting a
second device. The separate `presim` timing row overlaps setup, so do not sum it with the
segment total; the job's instrumented span includes that overlap only once.

### Measured startup baseline

The timestamp-only baseline is [run 44440086157](https://github.com/akshob/homespun/actions/runs/44440086157)
at `55cc7d4`: **329.6 macOS machine-minutes**, or **204.4 minutes including shared-runner queues**.
Its iPhone lane failed ItemViewer's Free Up state assertion and reachability on retry; the
other lanes passed. Test windows include retries, so compare startup phases separately.

| Phase | Baseline seconds |
|---|---:|
| Duo open: segment start → server launch (cover for comparison) | 1085 (325) |
| Duo open: initial pose / fixed wait / seed import | 150 / 15 / 572 |
| EXTRA: generation / import, iPhone 200 items | 30 / 221 |
| DATED 240: generation / import, iPhone and Duo | 19–74 / 10–13 |
| Unit: simulator / xcodebuild preparation / tests / teardown | 193 / 365 / 32 / 150 |
| Brew, all macOS jobs | 21–38 |

The Duo gap is not solely the first pose: media import dominates it. Keep pose/media
ordering changes separate from package-free test execution. Fresh simulator setup
(create, boot, privacy) plus seed import took **227 / 243 / 193 seconds** in copies,
iPhone and unit respectively (unit has no seed import). That meets the 150-second
threshold for considering later reuse **only** within the same-seed `iphone-flows` job;
background preparation does not itself reuse a simulator between segments.

## Repository settings

- Actions › fork pull requests: approval required for all outside contributors.
- Environment `testflight`: deployments from `main` only, the owner as required reviewer; secrets
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the `.p8` file's contents) and `DEVELOPMENT_TEAM`.
- `main` is protected: no force pushes or deletion; changes come through pull requests whose
  quick checks (`PR / Result`) passed.
- Environment `website`: deployments from `main` only; secrets `CLOUDFLARE_API_TOKEN` (Cloudflare
  Pages edit only) and `CLOUDFLARE_ACCOUNT_ID`.
- Private vulnerability reporting on.

## Reading results without opening a browser

```sh
gh run watch                      # the latest run, live
gh run view <id> --log-failed     # only what failed
gh run download <id> -D ci-results/downloaded    # timing metadata, or a failure's full results
```
