#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Turns a run's result bundles into a short Markdown report (the job summary): counts per bundle,
each failing test with its message, and performance lines. CI tooling only.

    summary.py <results folder> [title]
"""
import glob, json, os, subprocess, sys
from timing import timing_summary

results, title = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "Tests")
lines = [f"### {title}", "", "| Run | Passed | Failed | Skipped |", "|---|---|---|---|"]
failures, perf = [], []
def retried(bundle):
    """Tests that failed and then passed when Xcode ran them again (RETRY_UI)."""
    try:
        out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
                             capture_output=True, text=True, timeout=120).stdout
        nodes = json.loads(out).get("testNodes", [])
    except Exception:
        return []
    found = []
    def walk(node):
        children = node.get("children", [])
        tries = [c for c in children if c.get("nodeType") == "Repetition"]
        if node.get("nodeType") == "Test Case" and node.get("result") == "Passed" \
                and any(t.get("result") == "Failed" for t in tries):
            found.append(node.get("name", "?"))
        for child in children:
            walk(child)
    for node in nodes:
        walk(node)
    return found


for bundle in sorted(glob.glob(os.path.join(results, "*.xcresult"))):
    name = os.path.basename(bundle)[:-len(".xcresult")]
    try:
        out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle],
                             capture_output=True, text=True, timeout=120).stdout
        summary = json.loads(out)
    except Exception as error:  # an interrupted run leaves an unreadable bundle
        lines.append(f"| {name} | – | unreadable ({error.__class__.__name__}) | – |")
        continue
    passed, failed, skipped = summary.get("passedTests", 0), summary.get("failedTests", 0), summary.get("skippedTests", 0)
    # A run that never got to its tests (no project, no simulator) failed too.
    mark = "❌" if failed or passed + failed + skipped == 0 else "✅"
    flaky = retried(bundle)
    if mark == "✅" and flaky:
        mark = "⚠️"
        failures += [f"- **{name}** `{test}`: flaky (failed, then passed when run again)" for test in flaky]
    lines.append(f"| {mark} {name} | {passed} | {failed} | {skipped} |")
    if passed + failed + skipped == 0:
        failures.append(f"- **{name}**: no tests ran (see the job's log)")
    for failure in summary.get("testFailures", []):
        text = " ".join(failure.get("failureText", "").split())[:300]
        failures.append(f"- **{name}** `{failure.get('testName', '?')}`: {text}")
for log in sorted(glob.glob(os.path.join(results, "*.log"))):
    perf += [line.strip() for line in open(log, errors="replace") if line.startswith("PERF ")]
quarantined = []
for listing in sorted(glob.glob(os.path.join(results, "*-quarantined.txt"))):
    quarantined += [line.split(maxsplit=1) for line in open(listing) if line.strip()]
if failures:
    lines += ["", "#### Failures", *failures]
if quarantined:
    lines += ["", "#### Skipped: known failures (ci/quarantine*.txt)",
              *[f"- `{parts[0]}` {parts[1] if len(parts) > 1 else ''}" for parts in quarantined]]
if perf:
    lines += ["", "#### Performance", "```", *perf, "```"]
lines += timing_summary(results)
report = "\n".join(lines) + "\n"
print(report)
path = os.environ.get("GITHUB_STEP_SUMMARY")
if path:
    with open(path, "a") as file:
        file.write(report)
