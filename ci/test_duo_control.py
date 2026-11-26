# SPDX-License-Identifier: Apache-2.0
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("duoctl_for_tests", str(ROOT / "tools/duoctl/duoctl"))
spec = importlib.util.spec_from_loader(loader.name, loader)
duoctl = importlib.util.module_from_spec(spec)
loader.exec_module(duoctl)


class DisplayTransitionTests(unittest.TestCase):
    def test_hinge_waits_for_a_transiently_inactive_display(self):
        clock = [0.0]
        inner = {"active": True, "primary": False}
        with patch.object(duoctl, "hinge_angle", return_value=0), \
             patch.object(duoctl, "helper") as helper, \
             patch.object(duoctl, "displays", side_effect=[[], [inner]]) as displays, \
             patch.object(duoctl.time, "time", side_effect=lambda: clock[0]), \
             patch.object(duoctl.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            duoctl.set_hinge("synthetic-simulator", 180)
        self.assertEqual(displays.call_count, 2)
        helper.assert_called_once_with("synthetic-simulator", "hinge-sweep", 0, 180, duoctl.MIN_SWEEP_SECONDS)

    def test_missing_display_still_fails_within_the_existing_switch_deadline(self):
        clock = [0.0]
        with patch.object(duoctl, "hinge_angle", return_value=0), \
             patch.object(duoctl, "helper"), \
             patch.object(duoctl, "displays", return_value=[]), \
             patch.object(duoctl.time, "time", side_effect=lambda: clock[0]), \
             patch.object(duoctl.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            with self.assertRaisesRegex(duoctl.DuoError, "inner screen did not become active"):
                duoctl.set_hinge("synthetic-simulator", 180)
        self.assertGreaterEqual(clock[0], duoctl.SCREEN_SWITCH_TIMEOUT)
        self.assertLess(clock[0], duoctl.SCREEN_SWITCH_TIMEOUT + duoctl.SETTLE_SECONDS)


class PoseRequestTests(unittest.TestCase):
    token = "11111111-1111-4111-8111-111111111111"
    next_token = "22222222-2222-4222-8222-222222222222"

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="duo-pose-")
        self.addCleanup(self.folder.cleanup)
        self.request = Path(self.folder.name) / "pose-request"
        self.trace = Path(self.folder.name) / "commands"

    def shell(self, body):
        script = f"""
source {shlex.quote(str(ROOT / "duo-poses.sh"))}
stamp() {{ :; }}
timed() {{ shift; "$@"; }}
sleep() {{ :; }}
{body}
"""
        return subprocess.run(["bash", "-c", script], text=True, capture_output=True, timeout=5,
                              env={**os.environ, "POSEFILE": str(self.request), "TRACE": str(self.trace),
                                   "SHOTS": self.folder.name, "NEXT_TOKEN": self.next_token})

    def test_failed_hinge_never_attempts_rotation(self):
        result = self.shell('pose_call() { echo "$*" >> "$TRACE"; return 1; }; apply_duo_pose landscape')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.trace.read_text().splitlines(), ["hinge 180"])

    def test_exhausted_rotation_retries_return_failure(self):
        result = self.shell('pose_call() { echo "$*" >> "$TRACE"; return 1; }; turn portrait')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.trace.read_text().splitlines(), ["rotate portrait"] * 4)

    def test_failed_host_action_gets_a_failed_result_not_a_successful_ack(self):
        self.request.write_text(self.token + "\nlandscape")
        result = self.shell("apply_duo_pose() { return 1; }; process_duo_pose_request")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(str(self.request) + "." + self.token + ".result").read_text().strip(), "failed")
        self.assertFalse(self.request.exists())
        self.assertFalse(Path(str(self.request) + ".inflight").exists())

    def test_late_old_completion_cannot_remove_a_newer_request(self):
        self.request.write_text(self.token + "\nlandscape")
        result = self.shell("""
apply_duo_pose() { printf '%s\\n%s' "$NEXT_TOKEN" portrait > "$POSEFILE"; return 0; }
process_duo_pose_request
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(str(self.request) + "." + self.token + ".result").read_text().strip(), "ok")
        self.assertEqual(self.request.read_text(), self.next_token + "\nportrait")
        self.assertFalse(Path(str(self.request) + ".inflight").exists())
