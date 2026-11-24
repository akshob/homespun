# SPDX-License-Identifier: Apache-2.0
"""Require every aggregate dependency to have passed or been intentionally skipped."""
import json
import os


def require_passed(needs):
    if not isinstance(needs, dict) or not needs:
        raise ValueError("Missing dependency results")
    results = {}
    for name, job in needs.items():
        if not isinstance(job, dict) or "result" not in job:
            raise ValueError(f"{name}: missing result")
        results[name] = job["result"]
    print("\n".join(f"{name}: {result}" for name, result in results.items()))
    bad = [name for name, result in results.items() if result not in ("success", "skipped")]
    if bad:
        raise ValueError(f"Not passed: {', '.join(bad)}")


if __name__ == "__main__":
    try:
        require_passed(json.loads(os.environ["NEEDS"]))
    except ValueError as error:
        raise SystemExit(str(error)) from None
