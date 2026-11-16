#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Symbolicates a MetricKit crash or hang report from the telemetry service (on a Mac with Xcode).

  symbolicate.py <payload.json> [build]

<payload.json> is the stored JSON (`wrangler r2 object get homespun-telemetry/<r2_key> --remote
--file payload.json`); the dSYM comes from ~/homespun-builds/<build>/ (testflight.sh keeps it), the
build being the crash's appBuildVersion unless given. Prints each crashed or hung thread, with
Homespun's frames resolved to functions and lines.
"""
import glob, json, os, subprocess, sys

if len(sys.argv) < 2:
    sys.exit(__doc__)
data = json.load(open(sys.argv[1]))
payload = data.get("payload", data)
reports = [("crash", c) for c in payload.get("crashDiagnostics", [])] + \
          [("hang", h) for h in payload.get("hangDiagnostics", [])]
if not reports:
    sys.exit("No crash or hang diagnostics in this payload.")


def frames(roots, depth=0):
    for frame in roots:
        yield depth, frame
        yield from frames(frame.get("subFrames", []), depth + 1)


for kind, report in reports:
    meta = report.get("diagnosticMetaData", {})
    build = sys.argv[2] if len(sys.argv) > 2 else meta.get("appBuildVersion", "")
    dwarf = glob.glob(os.path.expanduser(f"~/homespun-builds/{build}/Homespun.app.dSYM/Contents/Resources/DWARF/Homespun"))
    print(f"== {kind}: {meta.get('appVersion')} ({build}) on {meta.get('deviceType')}, {meta.get('osVersion')}")
    print(f"   {meta.get('terminationReason') or ''} exception {meta.get('exceptionType')} signal {meta.get('signal')}")
    reason = meta.get("objectiveCexceptionReason") or {}
    if reason:
        print(f"   {reason.get('exceptionName')}: {reason.get('composedMessage')}")
    if not dwarf:
        print(f"   (no dSYM in ~/homespun-builds/{build}; Homespun frames stay as offsets)")
    stacks = report["callStackTree"]["callStacks"]
    for stack in [s for s in stacks if s.get("threadAttributed")] or stacks[:1]:
        lines = list(frames(stack["callStackRootFrames"]))
        offsets = [hex(0x100000000 + f["offsetIntoBinaryTextSegment"]) for _, f in lines if f.get("binaryName") == "Homespun"]
        names = []
        if dwarf and offsets:
            names = subprocess.run(["atos", "-o", dwarf[0], "-arch", "arm64", "-l", "0x100000000", *offsets],
                                   capture_output=True, text=True).stdout.splitlines()
        for depth, frame in lines:
            text = f"{frame.get('binaryName')} +{frame.get('offsetIntoBinaryTextSegment')}"
            if frame.get("binaryName") == "Homespun" and names:
                text = "Homespun  " + names.pop(0)
            print(f"   {depth:>2} {text}")
