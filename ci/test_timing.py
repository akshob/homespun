# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import os
import shutil
import sqlite3
import subprocess
import unittest
from uuid import uuid4

from timing import collect, read_events, timing_summary


class TimingTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1] / "ci-results" / f"timing-test-{uuid4().hex}"
        self.root.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.root)

    def write_events(self, name, events):
        (self.root / f"{name}-timing.tsv").write_text(
            "".join(f"{name}\t{phase}\t{epoch}\n" for phase, epoch in events))

    def test_reboot_retry_counts_both_attempts_and_excludes_in_test_poses(self):
        self.write_events("duo", [
            ("segment.start", 100), ("simulator.bootstatus.start", 100),
            ("simulator.bootstatus.end", 120), ("media.seed.add.start", 120),
            ("media.seed.add.end", 130), ("server.pair.start", 130),
            ("server.pair.end", 135), ("xcodebuild.start", 135), ("xcodebuild.end", 150),
            ("simulator.reboot.start", 150), ("simulator.reboot.end", 160),
            ("xcodebuild.start", 160), ("xcodebuild.first-test", 180),
            ("pose.request.start", 190), ("pose.hinge.start", 190),
            ("pose.hinge.end", 195), ("pose.request.end", 195),
            ("xcodebuild.last-test", 210), ("xcodebuild.end", 215),
            ("cleanup.start", 215), ("cleanup.end", 220), ("segment.end", 220),
        ])
        self.assertIn("| duo | 30 | 10 | 5 | 35 | 30 | 10 | 120 |",
                      timing_summary(self.root))

    def test_cancelled_and_truncated_timings_do_not_claim_completed_phases(self):
        self.write_events("unit", [
            ("segment.start", 100), ("simulator.bootstatus.start", 100),
            ("simulator.bootstatus.end", 125), ("xcodebuild.start", 125),
            ("xcodebuild.first-test", 150),
        ])
        with (self.root / "unit-timing.tsv").open("a") as file:
            file.write("unit\tcleanup.start\t\nunit\tsegment")
        self.assertIn("| unit | 25 | – | – | – | – | – | ≥50 |",
                      timing_summary(self.root))
        self.assertEqual(timing_summary(self.root / "missing"), [])

    def test_collection_keeps_all_segments_and_sqlite_but_no_payloads(self):
        for name in ("demo", "demo-duo"):
            self.write_events(name, [("segment.start", 100), ("segment.end", 110)])
            (self.root / f"{name}.log").write_text("synthetic log")
            bundle = self.root / f"{name}.xcresult"
            (bundle / "Data").mkdir(parents=True)
            (bundle / "Data" / "large-payload").write_bytes(b"not for timing")
            with sqlite3.connect(bundle / "database.sqlite3") as database:
                database.execute("CREATE TABLE timing (epoch INTEGER)")
                database.execute("INSERT INTO timing VALUES (100)")
        destination = self.root / "collected"
        collect(self.root, destination)
        self.assertEqual(len(list(destination.glob("*-timing.tsv"))), 2)
        self.assertEqual(len(list(destination.glob("*.log"))), 2)
        self.assertFalse(list(destination.glob("*.xcresult/Data")))
        for database in destination.glob("*.xcresult/database.sqlite3"):
            with sqlite3.connect(database) as connection:
                self.assertEqual(connection.execute("SELECT epoch FROM timing").fetchone(), (100,))

    def run_zsh(self, script):
        if not shutil.which("zsh"):
            self.skipTest("zsh is only required by the macOS CI scripts")
        return subprocess.run(
            ["zsh", "-c", 'source "$ROOT/ci/env.sh"\nNAME=probe\n' + script],
            env={**os.environ, "ROOT": str(Path(__file__).resolve().parents[1]),
                 "CI_STATE": str(self.root / "state"), "RESULTS": str(self.root)},
            capture_output=True, text=True, timeout=15)

    def test_shell_stamps_do_not_corrupt_command_substitutions_or_status(self):
        run = self.run_zsh("""
SIM=$(timed simulator.create printf synthetic-udid)
print -r -- "$SIM"
timed server.pair sh -c 'exit 7'
exit $?
""")
        self.assertEqual(run.stdout, "synthetic-udid\n")
        self.assertEqual(run.returncode, 7, run.stderr)
        self.assertEqual([phase for phase, _ in read_events(self.root / "probe-timing.tsv")],
                         ["simulator.create.start", "simulator.create.end",
                          "server.pair.start", "server.pair.end"])

    def test_filter_stamps_xctest_and_swift_testing_and_preserves_pipeline_status(self):
        for output in ("Test Case 'synthetic' started.\nTest Case 'synthetic' passed (1.0 seconds).",
                       "◇ Test run started.\n✔ Test run with 2 tests passed after 1.0 seconds."):
            with self.subTest(output=output):
                timing = self.root / "probe-timing.tsv"
                timing.unlink(missing_ok=True)
                run = self.run_zsh(f"""
producer() {{ print -r -- "{output}"; return 9; }}
producer | filter
exit ${{pipestatus[1]}}
""")
                self.assertEqual(run.returncode, 9, run.stderr)
                self.assertEqual(run.stdout, output + "\n")
                self.assertEqual([phase for phase, _ in read_events(timing)],
                                 ["xcodebuild.first-test", "xcodebuild.last-test"])


if __name__ == "__main__":
    unittest.main()
