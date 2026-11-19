# SPDX-License-Identifier: Apache-2.0
"""Phase timing summaries and small, always-uploaded CI timing artifacts."""
from collections import defaultdict
from pathlib import Path
import shutil
import sqlite3
import sys


def read_events(path):
    events = []
    for line in path.read_text().splitlines():
        fields = line.split("\t")
        if len(fields) != 3:
            continue  # A cancelled process may leave a partial last line.
        try:
            events.append((fields[1], int(fields[2])))
        except ValueError:
            continue
    return sorted(events, key=lambda event: event[1])


def intervals(events):
    starts = defaultdict(list)
    found = defaultdict(list)
    for phase, epoch in events:
        if phase.endswith(".start"):
            starts[phase[:-6]].append(epoch)
        elif phase.endswith(".end") and starts[phase[:-4]]:
            found[phase[:-4]].append((starts[phase[:-4]].pop(0), epoch))
    return found


def timing_summary(results):
    paths = sorted(Path(results).glob("*-timing.tsv"))
    if not paths:
        return []
    lines = ["", "#### Timing", "",
             "Seconds; **–** means unavailable. Totals marked **≥** are incomplete.",
             "Pose requests overlap tests and are not added to simulator setup.", "",
             "| Segment | Sim | Media | Server | xcodebuild prep | Tests | Teardown | Total |",
             "|---|---:|---:|---:|---:|---:|---:|---:|"]
    job_events = []
    for path in paths:
        events = read_events(path)
        if not events:
            continue
        job_events.extend(events)
        spans = intervals(events)

        def seconds(prefix):
            durations = [end - start for phase, pairs in spans.items()
                         if phase == prefix or phase.startswith(prefix + ".")
                         for start, end in pairs]
            return str(sum(durations)) if durations else "–"

        prep, tests, tail = [], [], []
        attempt = {}
        for phase, epoch in events:
            if phase == "xcodebuild.start":
                attempt = {"start": epoch}
            elif phase.startswith("xcodebuild.") and attempt:
                attempt[phase.split(".", 1)[1]] = epoch
                if phase == "xcodebuild.end":
                    prep.append(attempt.get("first-test", epoch) - attempt["start"])
                    if "first-test" in attempt and "last-test" in attempt:
                        tests.append(attempt["last-test"] - attempt["first-test"])
                        tail.append(epoch - attempt["last-test"])
                    attempt = {}
        cleanup = [end - start for start, end in spans.get("cleanup", [])]
        teardown = str(sum(tail + cleanup)) if tail or cleanup else "–"
        total = seconds("segment")
        if total == "–":
            total = f"≥{events[-1][1] - events[0][1]}"
        row = [path.name.removesuffix("-timing.tsv"), seconds("simulator"),
               seconds("media"), seconds("server"),
               str(sum(prep)) if prep else "–", str(sum(tests)) if tests else "–",
               teardown, total]
        lines.append("| " + " | ".join(row) + " |")
    if job_events:
        elapsed = max(epoch for _, epoch in job_events) - min(epoch for _, epoch in job_events)
        lines += ["", f"Job instrumented span: **{elapsed} s ({elapsed / 60:.1f} min)**.",
                  "Checkout, brew, artifact transfer and summary time are in the Actions step timings; "
                  "phase details (bootstatus, pose, EXTRA/DATED, pairing) are in the timing artifact."]
    return lines


def collect(results, destination):
    """Keep logs and SQLite metadata, never xcresult's large image/video Data directory."""
    results, destination = Path(results), Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for pattern in ("*-timing.tsv", "*.log"):
        for source in results.glob(pattern):
            if source.is_file():
                shutil.copy2(source, destination / source.name)
    for source in results.glob("*.xcresult/database.sqlite3"):
        target = destination / source.parent.name / source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        # Include committed WAL pages too if an interrupted runner left a journal behind.
        with sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True) as original:
            with sqlite3.connect(target) as copy:
                original.backup(copy)


if __name__ == "__main__":
    collect(*sys.argv[1:])
