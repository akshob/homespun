# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import plistlib
import tempfile
import unittest

from check_archive import ArchiveError, check_archive


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.app = Path(self.directory.name) / "Homespun.app"

    def tearDown(self):
        self.directory.cleanup()

    def bundle(self, relative="", suffix="", *, features="YES", version="1.1.0", build="202611241200"):
        directory = self.app / relative
        directory.mkdir(parents=True, exist_ok=True)
        info = {"CFBundleIdentifier": "photos.homespun.app" + suffix,
                "HomespunReleaseFeatures": features, "CFBundleShortVersionString": version,
                "CFBundleVersion": build}
        if suffix == ".watchkitapp":
            info["WKCompanionAppBundleIdentifier"] = "photos.homespun.app"
        with (directory / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)

    def feature_bundles(self):
        self.bundle()
        self.bundle("PlugIns/HomespunWidgets.appex", ".widgets")
        self.bundle("Watch/HomespunWatch.app", ".watchkitapp")
        self.bundle("Watch/HomespunWatch.app/PlugIns/HomespunWatchWidgets.appex", ".watchkitapp.widgets")

    def check(self, features=True):
        check_archive(self.app, features=features, version="1.1.0", build="202611241200")

    def test_feature_release_requires_all_embedded_targets_with_matching_versions(self):
        self.feature_bundles()
        self.check()
        self.bundle("Watch/HomespunWatch.app/PlugIns/HomespunWatchWidgets.appex", ".watchkitapp.widgets",
                    build="202611241159")
        with self.assertRaises(ArchiveError):
            self.check()

    def test_rejects_missing_watch_complication_and_mismatched_feature_setting(self):
        self.bundle()
        self.bundle("PlugIns/HomespunWidgets.appex", ".widgets")
        self.bundle("Watch/HomespunWatch.app", ".watchkitapp")
        with self.assertRaises(ArchiveError):
            self.check()
        self.bundle("Watch/HomespunWatch.app/PlugIns/HomespunWatchWidgets.appex", ".watchkitapp.widgets",
                    features="NO")
        with self.assertRaises(ArchiveError):
            self.check()

    def test_disabled_archive_must_not_embed_retained_targets(self):
        self.bundle(features="NO")
        self.check(features=False)
        self.bundle("PlugIns/HomespunWidgets.appex", ".widgets", features="NO")
        with self.assertRaises(ArchiveError):
            self.check(features=False)

    def test_rejects_foreign_embedded_bundle_identity(self):
        self.feature_bundles()
        self.bundle("PlugIns/HomespunWidgets.appex", ".foreign")
        with self.assertRaises(ArchiveError):
            self.check()
