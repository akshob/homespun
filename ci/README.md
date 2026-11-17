# Continuous integration

Every change is validated by GitHub Actions (`.github/workflows`), not by hand:

| Workflow | When | What |
|---|---|---|
| `ci.yml` | every push | server build and tests on Linux, the telemetry Worker, the package on macOS, the app's build and unit tests (PhotoKit ones included), UI smoke |
| `ci.yml` | pull request to `main`, or Run workflow › `full` | the whole UI suite, one run per machine at once: iPhone (`iphone`, `library`, `later`, `copies`, `onboarding`, `telemetry`) and iPhone Duo (`duo-cover`, `duo-open` in every pose) |
| `testflight.yml` | on demand, by the owner, who approves each run | archive, sign in Apple's cloud, upload, wait until the build is ready; the symbols stay as the run's `dsyms-<build>` artifact |

All of it runs on GitHub's own machines, free for a public repository: Linux (`ubuntu-24.04`, the
server in the `swift:6.3-noble` container) and macOS (`xcode-27`: Xcode 27.2 with the iOS 27.2
simulators for iPhone 18 Pro and iPhone Duo). The macOS build job builds once and passes the app,
its tests and the release server to the other jobs as an archive (`build`). Every job starts on a
fresh machine. Pull requests from forks run after the owner approves them and never see secrets.

Performance runs nightly on polonium (a Mac mini with the 35,000-photo iPhone Duo simulator) from
the private repository `akshob/homespun-perf`, which tests this repository's `main`: a self-hosted
runner attached to a public repository would run anyone's pull request on that Mac.

## The scripts (`ci/`)

All of them work on any Mac with Xcode 27.2, XcodeGen, ffmpeg and the iPhone Duo simulator runtime
(each picks the newest runtime installed for the device):

| Script | Does |
|---|---|
| `build.sh` | release server + `build-for-testing` into `~/ci/dd/<commit>` (once per commit; later jobs reuse it) |
| `unit.sh` | app unit tests on a fresh iPhone simulator with Photos access |
| `ui.sh <name> <device> <tests> <port> [open]` | UI tests on a fresh simulator against a temporary server (`EXTRA=`, `DATED=`, `DUO_POSES=1`, `STUB_PORT=`) |
| `dated-photos.swift` | small synthetic photos taken over the past months (EXIF dates) for `DATED=`: month headers, scrolling across months |
| `later.sh`, `copies.sh` | the compact-later and copy-finder end-to-end runs |
| `lane.sh <run\|group> ...` | UI runs by name (`smoke`, `iphone`, `library`, …) or group (`iphone-all`, `duo-all`, `full`) |
| `tools/duoctl/` | folds, turns and screenshots the iPhone Duo simulator |
| `perf.sh`, `setup-perf-sim.sh` | performance budgets; the performance simulator (once) |
| `summary.py <results>` | the Markdown report each job adds to its summary |
| `reset.sh` | stops what a cancelled job of this runner left running |

Results (`*.xcresult`, logs, Duo screenshots) are in `ci-results/`, uploaded when a job fails.

On polonium (16 GB), at most two simulators run at once on the whole Mac, whoever starts them:
every script that boots one first takes a slot (`take_sim_slot` in `env.sh`, lock files in
`/Users/Shared/homespun-sim-slots`) and waits for a free one. Anyone running simulators there by
hand takes a slot the same way. Cancelling a job stops only its step's shell, so each job records
what it starts and `reset.sh` (first and last step of every Apple job, also when cancelled) stops
what an earlier job of the same runner left running and deletes its simulators.

## polonium's performance runner (once)

The owner does steps 1–2 (they need an administrator's password); the rest is scripted.

1. Create the account and its home folder, and let it log in over SSH with the same keys as yours:

   ```sh
   sudo sysadminctl -addUser homespun-ci -fullName "Homespun CI" -password -
   sudo createhomedir -c -u homespun-ci
   sudo dseditgroup -o edit -a homespun-ci -t user com.apple.access_ssh 2>/dev/null || true
   sudo mkdir -p /Users/homespun-ci/.ssh && sudo cp ~/.ssh/authorized_keys /Users/homespun-ci/.ssh/
   sudo chown -R homespun-ci:staff /Users/homespun-ci/.ssh && sudo chmod 700 /Users/homespun-ci/.ssh
   ```

2. Log in to the account once on polonium's screen (Fast User Switching: menu bar › your name ›
   Homespun CI), then switch back to yours **without logging it out**. Simulators need that session;
   after polonium restarts, log in to it once again.

3. Then, over SSH as `homespun-ci`: `ci/install-runner.sh polonium-perf <token>` (the token from
   `gh api -X POST repos/akshob/homespun-perf/actions/runners/registration-token --jq .token`)
   downloads the Actions runner, registers it with `akshob/homespun-perf` (labels `self-hosted,
   macOS, homespun-ci`) and starts it as a launch agent. Then `ci/setup-perf-sim.sh` (about 40
   minutes) makes the performance simulator.

## Repository settings (done)

- Actions › fork pull requests: approval required for all outside contributors.
- Environment `testflight`: deployments from `main` only, the owner as required reviewer; secrets
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the `.p8` file's contents) and `DEVELOPMENT_TEAM`.
- Private vulnerability reporting on.

## Reading results without opening a browser

```sh
gh run watch                      # the latest run, live
gh run view <id> --log-failed     # only what failed
gh run download <id> -D /tmp/r    # the failure's result bundles and screenshots
```
