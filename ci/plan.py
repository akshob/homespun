#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Decides what a CI run needs, so GitHub's few macOS machines (5 at once) do only useful work.
Writes key=value lines to $GITHUB_OUTPUT and a short note to the job summary.

  server     the server changed: package tests on Linux (and on macOS for main and pull requests)
  telemetry  the telemetry Worker changed
  app        anything the app or its tests use changed: build and unit tests
  package    macOS package tests
  ui         the UI runs, as a JSON list ([] for none)
  site       the website changed: check it (site-check.py, html-validate)
  deploy     publish the website to homespun.photos (main only)

What runs, by event:
  pull request, ready   everything that changed; the whole UI suite
  pull request, draft   everything that changed; UI smoke
  push to main          everything that changed; UI smoke
  push to a branch      nothing when the branch has an open pull request (its run covers it);
                        otherwise build and unit tests (Run workflow › smoke or full for UI runs)
  Run workflow          everything, with the UI runs asked for
Changes to design files or Markdown alone run nothing; the website alone runs only its checks (and
its deploy, on main).
"""
import json, os, subprocess, sys

FULL = ["iphone", "library", "later", "copies", "onboarding", "telemetry", "duo-cover", "duo-grid", "duo-open"]
ZERO = "0" * 40


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True).stdout


def changed_files(event, base_ref, before, sha):
    if event == "pull_request":
        return git("diff", "--name-only", f"origin/{base_ref}...{sha}").split()
    if before and before != ZERO and git("cat-file", "-t", before).strip() == "commit":
        return git("diff", "--name-only", before, sha).split()
    # A new branch: what it adds to main.
    return git("diff", "--name-only", f"origin/main...{sha}").split()


def ignored(path):
    return path.startswith(("site/", "design/")) or path.endswith(".md")


def touches(files, prefixes, exact=()):
    return any(f.startswith(prefixes) or f in exact for f in files if not ignored(f))


def plan(env, files, open_pull_request):
    event, ref = env["EVENT"], env["REF_NAME"]
    if event == "workflow_dispatch":
        ui = {"none": [], "smoke": ["smoke"], "full": FULL}[env.get("UI_INPUT") or "smoke"]
        return {"server": True, "telemetry": True, "app": True, "package": True, "ui": ui,
                "site": True, "deploy": ref == "main", "why": f"Run workflow ({env.get('UI_INPUT') or 'smoke'})"}
    if event == "push" and ref != "main" and open_pull_request:
        return {"server": False, "telemetry": False, "app": False, "package": False, "ui": [],
                "site": False, "deploy": False, "why": f"{ref} has an open pull request; its run covers this commit"}
    workflow = (".github/workflows/ci.yml",)
    package = ("Package.swift", "Package.resolved")
    server = touches(files, ("Sources/", "Tests/"), package + workflow)
    telemetry = touches(files, ("services/telemetry/",), workflow)
    app = touches(files, ("Apps/", "Sources/", "ci/"), package + workflow)
    site = any(f.startswith("site/") for f in files) or touches(files, (), workflow + ("ci/site-check.py", "ci/htmlvalidate.json"))
    draft = env.get("DRAFT") == "true"
    if not app:
        ui = []
    elif event == "pull_request":
        ui = ["smoke"] if draft else FULL
    elif ref == "main":
        ui = ["smoke"]
    else:
        ui = []
    main_or_pr = event == "pull_request" or ref == "main"
    kind = "draft pull request" if event == "pull_request" and draft else event.replace("_", " ")
    return {"server": server, "telemetry": telemetry, "app": app, "package": server and main_or_pr, "ui": ui,
            "site": site, "deploy": site and event == "push" and ref == "main",
            "why": f"{kind} on {ref}: {len(files)} files changed"}


def main():
    env = os.environ
    files = [] if env["EVENT"] == "workflow_dispatch" else \
        changed_files(env["EVENT"], env.get("BASE_REF", ""), env.get("BEFORE", ""), env["SHA"])
    open_pr = False
    if env["EVENT"] == "push" and env["REF_NAME"] != "main":
        out = subprocess.run(["gh", "pr", "list", "--head", env["REF_NAME"], "--state", "open", "--json", "number"],
                             capture_output=True, text=True).stdout
        open_pr = bool(json.loads(out or "[]"))
    result = plan(env, files, open_pr)
    lines = [f"{key}={json.dumps(value) if key == 'ui' else str(value).lower()}"
             for key, value in result.items() if key != "why"]
    with open(env.get("GITHUB_OUTPUT", "/dev/stdout"), "a") as out:
        out.write("\n".join(lines) + "\n")
    summary = (f"### Plan\n{result['why']}. Server: {result['server']}, telemetry: {result['telemetry']}, "
               f"app: {result['app']}, macOS package tests: {result['package']}, "
               f"UI: {', '.join(result['ui']) or 'none'}, website: {result['site']}, deploy: {result['deploy']}.\n")
    print(summary)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a") as out:
            out.write(summary)


if __name__ == "__main__":
    sys.exit(main())
