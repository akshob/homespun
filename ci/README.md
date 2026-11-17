# Continuous integration

Every change is validated by GitHub Actions (`.github/workflows`), not by hand:

| Workflow | When | What |
|---|---|---|
| `ci.yml` | pull request to `main` | what changed: the server on Linux and macOS, the telemetry Worker, the app's build and unit tests (PhotoKit ones included), and the whole UI suite, one run per machine at once: iPhone (`iphone`, `library`, `later`, `copies`, `onboarding`, `telemetry`) and iPhone Duo (`duo-cover`, `duo-open` in every pose). A draft pull request gets UI smoke only. |
| `ci.yml` | push to `main` | what changed, with UI smoke |
| `ci.yml` | push to another branch | build and unit tests, or nothing if the branch has an open pull request (that run covers it) |
| `ci.yml` | Run workflow (any branch) | everything, with UI runs `none`, `smoke` or `full` |
| `ci.yml` | a change to `site/` | the website's checks (`site-check.py`, html-validate); from `main`, published to homespun.photos (environment `website`) |
| `testflight.yml` | on demand, by the owner, who approves each run | archive, sign in Apple's cloud, upload, wait until the build is ready; the symbols stay as the run's `dsyms-<build>` artifact |

`ci/plan.py` decides what a run needs from the files it changes (design files and Markdown alone run
nothing; the website alone runs only its checks and deploy), because GitHub gives this account five
macOS machines at once. The `CI result` job sums the run up; `main` requires it to pass.

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
| `build.sh` | release server + `build-for-testing` into `~/ci/dd/<commit>` (once per commit; later jobs reuse it) |
| `unit.sh` | app unit tests on a fresh iPhone simulator with Photos access |
| `ui.sh <name> <device> <tests> <port> [open]` | UI tests on a fresh simulator against a temporary server (`EXTRA=`, `DUO_POSES=1`, `STUB_PORT=`) |
| `later.sh`, `copies.sh` | the compact-later and copy-finder end-to-end runs |
| `lane.sh <run\|group> ...` | UI runs by name (`smoke`, `iphone`, `library`, …) or group (`iphone-all`, `duo-all`, `full`) |
| `tools/duoctl/` | folds, turns and screenshots the iPhone Duo simulator |
| `perf.sh`, `setup-perf-sim.sh` | performance budgets; the performance simulator (once) |
| `plan.py` | what a run needs (see above) |
| `site-check.py`, `htmlvalidate.json` | the website's checks |
| `summary.py <results>` | the Markdown report each job adds to its summary |

Results (`*.xcresult`, logs, Duo screenshots) are in `ci-results/`, uploaded when a job fails.

On a Mac shared by several jobs, set `SIM_SLOTS_DIR` to limit how many simulators boot at once
(see `env.sh`).

## Repository settings

- Actions › fork pull requests: approval required for all outside contributors.
- Environment `testflight`: deployments from `main` only, the owner as required reviewer; secrets
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the `.p8` file's contents) and `DEVELOPMENT_TEAM`.
- `main` is protected: no force pushes or deletion; changes come through pull requests whose CI
  passed.
- Environment `website`: deployments from `main` only; secrets `CLOUDFLARE_API_TOKEN` (Cloudflare
  Pages edit only) and `CLOUDFLARE_ACCOUNT_ID`.
- Private vulnerability reporting on.

## Reading results without opening a browser

```sh
gh run watch                      # the latest run, live
gh run view <id> --log-failed     # only what failed
gh run download <id> -D /tmp/r    # the failure's result bundles and screenshots
```
