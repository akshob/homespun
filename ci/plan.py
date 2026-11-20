#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Decides what a CI run needs, so GitHub's few macOS machines (5 at once) do only useful work.
Writes key=value lines to $GITHUB_OUTPUT and a short note to the job summary.

  server     the server changed: its tests on Linux
  telemetry  the telemetry Worker changed
  site       the website changed: its checks
  app        anything the app or its tests use changed: macOS build and unit tests
  package    the server's package tests on macOS too (after merge)
  ui         the UI runs, as a JSON list ([] for none)

MODE (set by the workflow):
  pr       pull request (pr.yml): quick checks of what changed: UI runs `quick` (iPhone) and
           `quick-duo` (iPhone Duo open, every pose), plus `watch` for watch-related changes;
           a draft gets build and unit tests only
  main     after a merge (ci.yml): what changed, with every UI run (the extended suite)
  manual   Run workflow (ci.yml, any branch): everything, with the UI runs asked for (UI_INPUT)
Nightly (nightly.yml) runs everything and needs no plan.
"""
import json, os, subprocess, sys

QUICK = ["quick", "quick-duo"]
FULL = ["iphone", "library", "later", "copies", "onboarding", "telemetry", "duo-cover", "duo-grid", "duo-open", "demo", "watch"]
WATCH_PATHS = ("Apps/Homespun/HomespunWatch/", "Apps/Homespun/HomespunWatchUITests/",
               "Apps/Homespun/Widgets/", "Apps/Homespun/Shared/")
ZERO = "0" * 40
WORKFLOWS = (".github/workflows/pr.yml", ".github/workflows/ci.yml", ".github/workflows/suite.yml")


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True).stdout


def changed_files(mode, base_ref, before, sha):
    if mode == "pr":
        return git("diff", "--name-only", f"origin/{base_ref}...{sha}").split()
    if before and before != ZERO and git("cat-file", "-t", before).strip() == "commit":
        return git("diff", "--name-only", before, sha).split()
    return git("diff", "--name-only", f"{sha}~1", sha).split()


def ignored(path):
    return path.startswith(("site/", "design/")) or path.endswith(".md")


def touches(files, prefixes, exact=()):
    return any(f.startswith(prefixes) or f in exact for f in files if not ignored(f))


def plan(env, files):
    mode = env["MODE"]
    if mode == "manual":
        choice = env.get("UI_INPUT") or "quick"
        if choice == "package":
            return {"server": False, "telemetry": False, "site": False, "app": False, "package": True,
                    "ui": [], "why": f"Run workflow on {env.get('REF_NAME', '?')} (macOS package only)"}
        if choice in ("watch", "duo-open"):
            return {"server": False, "telemetry": False, "site": False, "app": True, "package": False,
                    "ui": [choice], "why": f"Run workflow on {env.get('REF_NAME', '?')} ({choice} only)"}
        ui = {"none": [], "quick": QUICK, "full": FULL}[choice]
        return {"server": True, "telemetry": True, "site": True, "app": True, "package": True, "ui": ui,
                "why": f"Run workflow on {env.get('REF_NAME', '?')} (UI: {choice})"}
    package = ("Package.swift", "Package.resolved")
    server = touches(files, ("Sources/", "Tests/"), package + WORKFLOWS)
    telemetry = touches(files, ("services/telemetry/",), WORKFLOWS)
    app = touches(files, ("Apps/", "Sources/", "ci/"), package + WORKFLOWS)
    site = any(f.startswith("site/") for f in files) or \
        touches(files, (), WORKFLOWS + ("ci/site-check.py", "ci/htmlvalidate.json"))
    if mode == "pr":
        draft = env.get("DRAFT") == "true"
        ui = list(QUICK) if app and not draft else []
        if app and not draft and touches(files, WATCH_PATHS, (
                "Apps/Homespun/project.yml", "Apps/Homespun/project-features.yml",
                "Apps/Homespun/ReleaseFeatures.xcconfig", "Apps/Homespun/scripts/generate-project.sh", "ci/watch.sh")):
            ui.append("watch")
        why = f"{'draft ' if draft else ''}pull request: {len(files)} files changed"
        return {"server": server, "telemetry": telemetry, "site": site, "app": app, "package": False, "ui": ui,
                "why": why}
    return {"server": server, "telemetry": telemetry, "site": site, "app": app, "package": server,
            "ui": FULL if app else [], "why": f"merged to main: {len(files)} files changed"}


def main():
    env = os.environ
    files = [] if env["MODE"] == "manual" else \
        changed_files(env["MODE"], env.get("BASE_REF", ""), env.get("BEFORE", ""), env["SHA"])
    result = plan(env, files)
    lines = [f"{key}={json.dumps(value) if key == 'ui' else str(value).lower()}"
             for key, value in result.items() if key != "why"]
    with open(env.get("GITHUB_OUTPUT", "/dev/stdout"), "a") as out:
        out.write("\n".join(lines) + "\n")
    summary = (f"### Plan\n{result['why']}. Server: {result['server']}, telemetry: {result['telemetry']}, "
               f"website: {result['site']}, app: {result['app']}, macOS package tests: {result['package']}, "
               f"UI: {', '.join(result['ui']) or 'none'}.\n")
    print(summary)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a") as out:
            out.write(summary)


if __name__ == "__main__":
    sys.exit(main())
