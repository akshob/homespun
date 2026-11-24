# SPDX-License-Identifier: Apache-2.0
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import unittest
from unittest.mock import patch
from uuid import uuid4

import apple_runtime_diagnostics as diagnostics


class AppleRuntimeDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1] / "ci-results" / f"apple-test-{uuid4().hex}"
        self.root.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_only_allowlisted_state_and_synthetic_partial_metadata_are_retained(self):
        secret = "secret-canary-must-not-be-archived"
        with sqlite3.connect(self.root / "homespun.db") as connection:
            connection.executescript("""
                CREATE TABLE assets(id TEXT, kind TEXT, state TEXT, message TEXT, device_id TEXT);
                CREATE TABLE resources(asset_id TEXT, role TEXT, state TEXT, stored_path TEXT, immich_asset_id TEXT);
                CREATE TABLE jobs(id INTEGER, status TEXT, last_error TEXT, lease_owner TEXT);
                CREATE TABLE devices(token_hash TEXT);
                CREATE TABLE settings(value TEXT);
                """)
            connection.execute("INSERT INTO assets VALUES ('asset','live_photo','stored',?,?)", (secret, secret))
            connection.execute("INSERT INTO resources VALUES ('asset','paired_video','verified',?,?)", (secret, secret))
            connection.execute("INSERT INTO jobs VALUES (1,'leased',?,?)", (secret, secret))
            connection.execute("INSERT INTO devices VALUES (?)", (secret,))
            connection.execute("INSERT INTO settings VALUES (?)", (secret,))
        staging = self.root / "staging"
        staging.mkdir()
        good = "a" * 64 + "-paired_video.partial"
        (staging / good).write_bytes(b"partial")
        (staging / "private-token-file.partial").write_text(secret)
        compact = self.root / "compact" / ("b" * 64)
        compact.mkdir(parents=True)
        (compact / ".partial-IMG_2001.MOV").write_bytes(b"motion")
        (compact / ".partial-private-party.MOV").write_text(secret)
        result = diagnostics.state_snapshot(self.root)
        text = json.dumps(result)
        self.assertNotIn(secret, text)
        self.assertEqual(set(result["tables"]), {"assets", "resources", "jobs"})
        self.assertEqual(result["tables"]["resources"],
                         [{"asset_id": "asset", "role": "paired_video", "state": "verified"}])
        self.assertEqual({row["filename"] for row in result["partials"]}, {good, ".partial-IMG_2001.MOV"})

    def test_reused_or_unrelated_pid_is_never_sampled(self):
        old = {"pid": 42, "ppid": 10, "birth": [1, 2], "exe": "/test/server"}
        new = {**old, "birth": [3, 4]}
        with patch.object(diagnostics, "identity", return_value=new), \
             patch.object(diagnostics.subprocess, "run") as sample:
            self.assertEqual(diagnostics.sample_owned(old, old, self.root / "sample.txt"), "refused_not_owned")
        sample.assert_not_called()

    def test_identity_change_discards_the_sample_instead_of_archiving_another_process(self):
        target = {"pid": 42}
        pending = self.root / "sample.pending"
        pending.write_text("must not survive")
        with patch.object(diagnostics, "owned", side_effect=[True, False]), \
             patch.object(diagnostics.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            self.assertEqual(diagnostics.sample_owned(target, target, self.root / "sample.txt"),
                             "discarded_identity_changed")
        self.assertFalse(pending.exists())
        self.assertFalse((self.root / "sample.txt").exists())

    def test_swift_testing_bundle_loader_is_sampled_instead_of_its_waiting_swiftpm_parent(self):
        owner = {"pid": 10}
        helper = {"pid": 42, "ppid": 10, "exe": "/toolchain/libexec/swift/pm/swiftpm-testing-helper"}
        codec = {"pid": 43, "ppid": 42, "exe": "/tools/ffmpeg"}
        with patch.object(diagnostics, "descendants", return_value=[helper, codec]), \
             patch.object(diagnostics, "sample_owned", return_value="captured") as sample:
            result = diagnostics.capture_package_stall(owner, self.root)
        sample.assert_called_once_with(helper, owner, self.root / "xctest-42.sample.txt")
        self.assertEqual(result, [{"pid": 42, "role": "test_runner", "sample": "captured"}])
        inventory = json.loads((self.root / "owned-processes.json").read_text())
        self.assertEqual(inventory[0]["executable"], "swiftpm-testing-helper")
        self.assertNotIn("/toolchain", json.dumps(inventory))

    def test_missing_runner_is_explicitly_identified_as_parent_only_evidence(self):
        owner = {"pid": 10}
        with patch.object(diagnostics, "descendants", return_value=[]), \
             patch.object(diagnostics, "identity", return_value=owner), \
             patch.object(diagnostics, "sample_owned", return_value="captured"):
            result = diagnostics.capture_package_stall(owner, self.root)
        self.assertEqual(result[0]["role"], "swiftpm_only_missing_test_runner")

    def test_synthetic_guard_rejects_real_data_and_symlinked_catalogs(self):
        with self.assertRaises(ValueError):
            diagnostics.synthetic_path(self.root / "real", self.root / "state")
        (self.root / "homespun.db").symlink_to(self.root / "outside.db")
        with self.assertRaises(ValueError):
            diagnostics.state_snapshot(self.root)
