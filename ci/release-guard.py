#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Before a TestFlight upload: the commit must have passed the extended suite (ci.yml after a merge),
or differ from one that did only in what the suite doesn't test (the website, design files, Markdown).
Needs GH_TOKEN and GH_REPO; run in a full checkout of the commit.

    release-guard.py <commit>
"""
import json, subprocess, sys

commit = sys.argv[1]


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout


runs = json.loads(gh("run", "list", "--workflow", "ci.yml", "--branch", "main", "--event", "push",
                     "--status", "success", "--limit", "50", "--json", "headSha"))
green = [run["headSha"] for run in runs]
if commit in green:
    print(f"{commit[:7]} passed the extended suite.")
    sys.exit(0)
for sha in green:
    ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", sha, commit]).returncode == 0
    if not ancestor:
        continue
    files = subprocess.run(["git", "diff", "--name-only", sha, commit], capture_output=True, text=True).stdout.split()
    tested = [f for f in files if not (f.startswith(("site/", "design/")) or f.endswith(".md"))]
    if not tested:
        print(f"{commit[:7]} differs from {sha[:7]}, which passed the extended suite, only in docs or the website.")
        sys.exit(0)
    print(f"{commit[:7]} hasn't passed the extended suite; since {sha[:7]} (the newest that did) it changes:")
    print("\n".join(f"  {f}" for f in tested[:20]))
    sys.exit(1)
print(f"No passing extended-suite run on main leads to {commit[:7]}.")
sys.exit(1)
