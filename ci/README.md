# Continuous integration

Every change is validated by GitHub Actions (`.github/workflows`), not by hand:

| Workflow | When | What |
|---|---|---|
| `ci.yml` | every push | server build and tests on Linux, the telemetry Worker, the package on macOS, the app's build and unit tests (PhotoKit ones included), UI smoke |
| `ci.yml` | pull request to `main`, or Run workflow › `full` | the whole UI suite: iPhone lane and iPhone Duo lane (folded, and open in every pose) at once |
| `perf.yml` | nightly 3:00 Pacific, or on demand | performance budgets on a 35,000-photo iPhone Duo simulator, launch time |
| `testflight.yml` | on demand, approved by the owner | archive, sign in the cloud, upload, wait until the build is ready |

Linux jobs run on GitHub's machines. Apple jobs run on polonium (a Mac mini) under its own macOS
account, `homespun-ci`, with two runner instances (`polonium-1`, `polonium-2`) so the two UI lanes
run together. That account can't read anyone else's files, the real Homespun Server's data
(`/Volumes/Homespun`) or signing keys; the TestFlight secrets reach it only for an approved run.
Apple jobs never run for a pull request from a fork. When the repository is public, fork pull
requests will run on GitHub's own macOS machines instead (free for public repositories), after
the owner approves them.

## The scripts (`ci/`)

All of them work on any Mac with Xcode 27.2, XcodeGen, ffmpeg and the iPhone Duo simulator runtime:

| Script | Does |
|---|---|
| `build.sh` | release server + `build-for-testing` into `~/ci/dd/<commit>` (once per commit; later jobs reuse it) |
| `unit.sh` | app unit tests on a fresh iPhone simulator with Photos access |
| `ui.sh <name> <device> <tests> <port> [open]` | UI tests on a fresh simulator against a temporary server (`EXTRA=`, `DUO_POSES=1`, `STUB_PORT=`) |
| `later.sh`, `copies.sh` | the compact-later and copy-finder end-to-end runs |
| `lane.sh smoke\|iphone\|duo` | the sets of runs the workflows use |
| `perf.sh`, `setup-perf-sim.sh` | performance budgets; the performance simulator (once) |
| `summary.py <results>` | the Markdown report each job adds to its summary |

Results (`*.xcresult`, logs, Duo screenshots) are in `ci-results/`, uploaded when a job fails.

## Setting up the runner account (once, on polonium)

The owner does steps 1–3 (they need an administrator's password); the rest is scripted.

1. Create the account and its home folder, let it log in over SSH with the same keys as yours, and
   make the shared folder for build symbols:

   ```sh
   sudo sysadminctl -addUser homespun-ci -fullName "Homespun CI" -password -
   sudo createhomedir -c -u homespun-ci
   sudo dseditgroup -o edit -a homespun-ci -t user com.apple.access_ssh 2>/dev/null || true
   sudo mkdir -p /Users/homespun-ci/.ssh && sudo cp ~/.ssh/authorized_keys /Users/homespun-ci/.ssh/
   sudo chown -R homespun-ci:staff /Users/homespun-ci/.ssh && sudo chmod 700 /Users/homespun-ci/.ssh
   sudo mkdir -p /Users/Shared/homespun-builds && sudo chmod 1777 /Users/Shared/homespun-builds
   ```

2. Log in to the account once on polonium's screen (Fast User Switching: menu bar › your name ›
   Homespun CI), then switch back to yours **without logging it out**. Simulators need that session;
   after polonium restarts, log in to it once again.

3. In the repository's settings: Actions › General › "Require approval for all external
   contributors" (for when the repository is public).

4. Then, over SSH as `homespun-ci`, `ci/install-runner.sh polonium-1 <token> <duoctl folder>` and
   `ci/install-runner.sh polonium-2 <token>` (the token from
   `gh api -X POST repos/akshob/homespun/actions/runners/registration-token --jq .token`): each
   downloads the Actions runner, registers it with the labels `self-hosted, macOS, homespun-ci` and
   starts it as a launch agent. Then `ci/setup-perf-sim.sh` (about 40 minutes).

5. The `testflight` environment: the owner as required reviewer; secrets `ASC_KEY_ID`,
   `ASC_ISSUER_ID`, `ASC_KEY_P8` (the `.p8` file's contents) and `DEVELOPMENT_TEAM`.

## Reading results without opening a browser

```sh
gh run watch                      # the latest run, live
gh run view <id> --log-failed     # only what failed
gh run download <id> -D /tmp/r    # the failure's result bundles and screenshots
```
