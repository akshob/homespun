# SPDX-License-Identifier: Apache-2.0
import json
from pathlib import Path
import shutil
import unittest
from uuid import uuid4

from snapshot_report import budget_exceeded, snapshot_summary


class SnapshotReportTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1] / "ci-results" / f"snapshot-report-{uuid4().hex}"
        (self.root / "snapshots").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_failure_summary_names_the_image_difference_and_artifact(self):
        rows = [{"suite": "Grid", "name": "badges.iphone.light.large", "result": "different",
                 "changedFraction": 0.002, "maximumDeltaE": 25.5, "elapsedSeconds": 0.3,
                 "referenceBytes": 400_000}]
        (self.root / "snapshots/report.json").write_text(json.dumps(rows))
        report = "\n".join(snapshot_summary(self.root, "https://example.invalid/artifact"))
        self.assertIn("Grid/badges.iphone.light.large", report)
        self.assertIn("0.2000% pixels over ΔE 2.3; max ΔE 25.50", report)
        self.assertIn("https://example.invalid/artifact", report)
        self.assertIn("exceeds 300 KB", report)
        self.assertFalse(budget_exceeded(self.root))

    def test_total_budget_counts_every_render_and_absent_reports_are_quiet(self):
        self.assertEqual(snapshot_summary(self.root), [])
        rows = [{"result": "passed", "elapsedSeconds": 100}, {"result": "recorded", "elapsedSeconds": 81}]
        (self.root / "snapshots/report.json").write_text(json.dumps(rows))
        self.assertTrue(budget_exceeded(self.root))
        self.assertIn("exceeded its three-minute budget", "\n".join(snapshot_summary(self.root)))
