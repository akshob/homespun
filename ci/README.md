# Continuous integration

Every change is validated by GitHub Actions (`.github/workflows`), not by hand. Quick checks gate a
pull request; the extended suite runs after the merge; everything runs every night.

| Workflow | When | What |
|---|---|---|
| `pr.yml` | pull request to `main` | quick checks of what it changes (about 20–25 minutes): the server on Linux, the telemetry Worker, the website, the app's build and unit tests (PhotoKit ones included), and two short UI runs side by side: `quick` (iPhone: pair, back up, compare, Keep Original, free up, the viewer, Select All, rename) and `quick-duo` (iPhone Duo open in every pose). Watch, widget, shared-status or project changes also run `watch`. A draft gets the build and unit tests only. `PR / Result` sums it up; `main` requires it. |
| `ci.yml` | after a merge to `main` | the extended suite: what changed, with every UI run, one per machine: iPhone (`iphone`, `library`, `later`, `copies`, `onboarding`, `telemetry`) and iPhone Duo (`duo-cover`, `duo-grid`, `duo-open`), Try the Demo on both (`demo`, no server), and the server's package tests on macOS; the website goes live when it changed (environment `website`). One run at a time; only the newest waiting merge runs next. A failure opens or updates the issue "main is failing"; a pass closes it. |
| `ci.yml` | Run workflow (any branch) | everything with UI runs `none`, `quick` or `full`; `watch` or `duo-open` builds the app, runs its unit tests and that regression lane only; `package` runs only the macOS package job |
| `nightly.yml` | every night | everything on `main`, plus long runs (`large`: 3,000 photos). Failures: the issue "nightly is failing". |
| `testflight.yml` | on demand, by the owner, who approves each run | only for a commit that passed the extended suite (`release-guard.py`); archive, sign in Apple's cloud, upload, wait until the build is ready; the symbols stay as the run's `dsyms-<build>` artifact |
| `docker.yml` | `main` and version tags, when the server changes | the server's Docker image |

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

Performance budgets (`perf.sh`) need a Mac with a large iPhone Duo library (`setup-perf-sim.sh`,
35,000 photos) and steady timings, which shared cloud machines don't give; the owner runs them
nightly on a Mac of their own, from a separate private repository, so no self-hosted runner is ever
attached to this public one.

## The scripts (`ci/`)

All of them work on any Mac with Xcode 27.2, XcodeGen, ffmpeg and the iPhone Duo simulator runtime
(each picks the newest runtime installed for the device):

| Script | Does |
|---|---|
| `build.sh` | typechecks `scripts/demo-media.swift` with `DemoArt.swift`, then release server + `build-for-testing` into `~/ci/dd/<commit>` (once per commit; later jobs reuse it); the app embeds its widgets and the Apple Watch app, so this also builds for the watchOS simulator (Xcode's watchOS SDK; no watch simulator runs) |
| `unit.sh` | app unit tests on a fresh iPhone simulator with Photos access, and the widgets' (`HomespunWidgetTests`, every size drawn) |
| `watch.sh` | separate watchOS build and timed Crown/swipe regression on a fresh Apple Watch simulator (fresh, stale and arriving status, each crossing a minute boundary); no server or paired iPhone; downloads the watchOS runtime if missing |
| `ui.sh <name> <device> <tests> <port> [open]` | UI tests on a fresh simulator against a temporary server (`EXTRA=`, `DATED=`, `DUO_POSES=1`, `STUB_PORT=`; `SERVERLESS=1`: no server and no Photos access, for the demo) |
| `dated-photos.swift` | small synthetic photos taken over the past months (EXIF dates) for `DATED=`: month headers, scrolling across months |
| `later.sh`, `copies.sh` | the compact-later and copy-finder end-to-end runs |
| `lane.sh <run\|group> ...` | UI runs by name (`quick`, `quick-duo`, `iphone`, `library`, …, `large`) or group (`pr`, `iphone-all`, `duo-all`, `full`); `RETRY_UI=1` retries a failed run once |
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
Test servers accept only HTTPS. Readiness probes derive an SPKI pin from that test server's
`tls/certificate.pem` and use `curl -k --pinnedpubkey`; port-occupancy checks are tokenless HTTPS
probes. Pairing links carry `fp=`, and address-and-code runs authenticate the server's code proof.
`ui.sh` gives tests `HOMESPUN_HOST_ACTION_FILE` (with the `TEST_RUNNER_` prefix when launching
Xcode); writing `rotate-key` there rotates only that run's temporary server key.
The address-recovery test uses `wrong-key-port` and `move-port`: it first refuses a separate-key
server, then restarts the original data/key on the lane's port plus 1000. A DEBUG-only candidate
list simulates Bonjour results in the simulator, but the TLS pin probe is real and cannot be
bypassed. The harness tracks the current server PID so every restarted server is stopped.
The pairing-retention UI test renames this iPhone, unpairs and pairs again with a fresh code
from the `pairing-code` host action. It checks the confirmed name and one active Devices row.

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

On a Mac shared by several jobs, set `SIM_SLOTS_DIR` to limit how many simulators boot at once
(see `env.sh`).

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
