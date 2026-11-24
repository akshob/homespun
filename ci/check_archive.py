# SPDX-License-Identifier: Apache-2.0
"""Verify the shipped feature set, bundle identities and version of an app archive."""

import argparse
from pathlib import Path
import plistlib
import sys


class ArchiveError(ValueError):
    pass


def check_archive(app: Path, *, features: bool, version: str, build: str) -> None:
    expected = "YES" if features else "NO"
    targets = [("", "")]
    widgets = "PlugIns/HomespunWidgets.appex"
    watch = "Watch/HomespunWatch.app"
    watch_widgets = watch + "/PlugIns/HomespunWatchWidgets.appex"
    if features:
        targets += [(widgets, ".widgets"), (watch, ".watchkitapp"),
                    (watch_widgets, ".watchkitapp.widgets")]
    elif (app / "Watch").exists() or list((app / "PlugIns").glob("*Widgets*.appex")):
        raise ArchiveError("Feature-disabled archive embeds widgets or a Watch app.")

    root_id = None
    for relative, suffix in targets:
        bundle = app / relative
        info_path = bundle / "Info.plist"
        if not info_path.is_file():
            raise ArchiveError(f"Required bundle is missing: {bundle}")
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        if not isinstance(info, dict):
            raise ArchiveError(f"Invalid Info.plist: {info_path}")
        if root_id is None:
            root_id = info.get("CFBundleIdentifier")
            if not isinstance(root_id, str) or not root_id:
                raise ArchiveError("The app has no bundle identifier.")
            if root_id != "photos.homespun.app":
                raise ArchiveError("The archive is not the release Homespun app.")
        if info.get("CFBundleIdentifier") != root_id + suffix:
            raise ArchiveError(f"Bundle identifier does not match the app: {bundle}")
        if info.get("HomespunReleaseFeatures") != expected:
            raise ArchiveError(f"Shipping feature setting does not match {expected}: {bundle}")
        if info.get("CFBundleShortVersionString") != version or str(info.get("CFBundleVersion")) != build:
            raise ArchiveError(f"Bundle version does not match {version} ({build}): {bundle}")
        if relative == watch and info.get("WKCompanionAppBundleIdentifier") != root_id:
            raise ArchiveError("The Watch app does not identify its companion iPhone app.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--features", choices=["YES", "NO"], required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    try:
        check_archive(args.app, features=args.features == "YES", version=args.version, build=args.build)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Archive verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Archive verified: {args.version} ({args.build}); shipping features {args.features}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
