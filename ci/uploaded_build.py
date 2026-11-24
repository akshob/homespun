# SPDX-License-Identifier: Apache-2.0
"""Extract exactly one uploaded build identity before waiting for TestFlight."""

import argparse
from pathlib import Path
import re
import sys


def uploaded_build(log: str) -> str:
    builds = re.findall(r"^Uploaded build ([1-9][0-9]*)(?:[ \t].*)?$", log, re.MULTILINE)
    if len(builds) != 1:
        raise ValueError(f"Expected exactly one uploaded build number; found {len(builds)}.")
    return builds[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    try:
        number = uploaded_build(args.log.read_text())
    except (OSError, ValueError) as error:
        print(f"TestFlight upload: {error}", file=sys.stderr)
        return 1
    print(number)
    return 0


if __name__ == "__main__":
    sys.exit(main())
