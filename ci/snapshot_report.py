# SPDX-License-Identifier: Apache-2.0
"""Snapshot-only job-summary data; the product renderer stays entirely in Swift."""
import json
from pathlib import Path
import sys

BUDGET_SECONDS = 180


def metrics(results):
    path = Path(results) / "snapshots" / "report.json"
    if not path.exists():
        return []
    return json.loads(path.read_text())


def budget_exceeded(results):
    return sum(row.get("elapsedSeconds", 0) for row in metrics(results)) > BUDGET_SECONDS


def snapshot_summary(results, artifact_url=""):
    try:
        rows = metrics(results)
    except (OSError, ValueError):
        return ["", "#### Snapshots", "Snapshot report is unreadable; see the job log."]
    if not rows:
        return []
    elapsed = sum(row.get("elapsedSeconds", 0) for row in rows)
    failures = [row for row in rows if row.get("result") not in ("passed", "recorded")]
    recorded = sum(row.get("result") == "recorded" for row in rows)
    lines = ["", "#### Snapshots",
             f"{len(rows)} images; {elapsed:.1f} s / {BUDGET_SECONDS} s budget"
             + (f"; {recorded} recorded." if recorded else ".")]
    if elapsed > BUDGET_SECONDS:
        lines.append("❌ Snapshot suite exceeded its three-minute budget.")
    if artifact_url:
        lines.append(f"[Reference / actual / diff PNGs and metrics]({artifact_url})")
    for row in failures:
        name = f"{row.get('suite', '?')}/{row.get('name', '?')}"
        fraction, maximum = row.get("changedFraction"), row.get("maximumDeltaE")
        detail = row.get("result", "failed")
        if fraction is not None and maximum is not None:
            threshold = row.get("deltaEThreshold", 2.3)
            detail = f"{fraction * 100:.4f}% pixels over ΔE {threshold:.1f}; max ΔE {maximum:.2f}"
        lines.append(f"- ❌ `{name}`: {detail}")
    for row in rows:
        if (row.get("referenceBytes") or 0) > 300 * 1024:
            lines.append(f"- ⚠️ `{row.get('suite')}/{row.get('name')}` exceeds 300 KB; keep references small and synthetic.")
    return lines


if __name__ == "__main__":
    if budget_exceeded(sys.argv[1]):
        raise SystemExit("Snapshot suite exceeded its three-minute budget")
