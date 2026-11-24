# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import shutil
import signal
import unittest
from unittest.mock import patch
from uuid import uuid4

import server_runtime_diagnostics as diagnostics


def stat(parent, started):
    return f"123 (worker (with) spaces) {' '.join(['S', str(parent)] + ['0'] * 17 + [str(started)])}"


class ServerRuntimeDiagnosticsTests(unittest.TestCase):
    def test_stat_parsing_handles_nested_parentheses_in_process_names(self):
        self.assertEqual(diagnostics.process_stat(stat(45, 99)), (45, 99))

    def test_unrelated_parent_is_never_adopted_or_signaled(self):
        with patch.object(diagnostics.os, "open", return_value=10), \
             patch.object(diagnostics, "read_at", return_value=stat(999, 99)), \
             patch.object(diagnostics.os, "close") as close, \
             patch.object(diagnostics.os, "pidfd_open", create=True) as acquire:
            self.assertIsNone(diagnostics.OwnedProcess.open(123, parent=45))
        acquire.assert_not_called()
        close.assert_called_once_with(10)

    def test_reused_process_identity_closes_both_handles_without_adopting(self):
        with patch.object(diagnostics.os, "open", return_value=10), \
             patch.object(diagnostics, "read_at", side_effect=[stat(45, 99), stat(45, 100)]), \
             patch.object(diagnostics.os, "close") as close, \
             patch.object(diagnostics.os, "pidfd_open", return_value=11, create=True):
            self.assertIsNone(diagnostics.OwnedProcess.open(123, parent=45))
        self.assertEqual({call.args[0] for call in close.call_args_list}, {10, 11})

    def test_signals_use_the_acquired_pidfd_not_a_reusable_numeric_pid(self):
        process = diagnostics.OwnedProcess(123, 11, 10, 99)
        with patch.object(diagnostics.signal, "pidfd_send_signal", create=True) as send, \
             patch.object(diagnostics.os, "kill") as numeric:
            process.send(signal.SIGQUIT)
        send.assert_called_once_with(11, signal.SIGQUIT, None, 0)
        numeric.assert_not_called()

    def test_focused_timeout_does_not_skip_the_real_full_suite_or_pass_the_job(self):
        root = Path(__file__).resolve().parents[1] / "ci-results" / f"runtime-test-{uuid4().hex}"
        results = [{"phase": name, "seconds": 1, "status": 124 if name == "process-cancel" else 0,
                    "timed_out": name == "process-cancel", "selection_started": True}
                   for name, _, _ in diagnostics.PHASES]
        try:
            for failure in (results[1], RuntimeError("synthetic capture failure")):
                with self.subTest(failure=failure), \
                     patch.object(diagnostics, "run_phase",
                                  side_effect=[results[0], failure, *results[2:]]) as run, \
                     patch.dict(diagnostics.os.environ, {"GITHUB_STEP_SUMMARY": ""}):
                    self.assertEqual(diagnostics.run_all(root), 1)
                self.assertEqual(len(run.call_args_list), 4)
                self.assertEqual(run.call_args_list[-1].args[:3], ("full", 300, None))
        finally:
            shutil.rmtree(root, ignore_errors=True)
