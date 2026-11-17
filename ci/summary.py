#!/usr/bin/env python3
"""Turns a run's result bundles into a short Markdown report (the job summary): counts per bundle,
each failing test with its message, and performance lines. CI tooling only.

    summary.py <results folder> [title]
"""
import glob, json, os, subprocess, sys

results, title = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "Tests")
lines = [f"### {title}", "", "| Run | Passed | Failed | Skipped |", "|---|---|---|---|"]
failures, perf = [], []
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
    mark = "❌" if failed else "✅"
    lines.append(f"| {mark} {name} | {passed} | {failed} | {skipped} |")
    for failure in summary.get("testFailures", []):
        text = " ".join(failure.get("failureText", "").split())[:300]
        failures.append(f"- **{name}** `{failure.get('testName', '?')}`: {text}")
for log in sorted(glob.glob(os.path.join(results, "*.log"))):
    perf += [line.strip() for line in open(log, errors="replace") if line.startswith("PERF ")]
if failures:
    lines += ["", "#### Failures", *failures]
if perf:
    lines += ["", "#### Performance", "```", *perf, "```"]
report = "\n".join(lines) + "\n"
print(report)
path = os.environ.get("GITHUB_STEP_SUMMARY")
if path:
    with open(path, "a") as file:
        file.write(report)
