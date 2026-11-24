# SPDX-License-Identifier: Apache-2.0
from contextlib import redirect_stdout
from io import StringIO
import unittest

from job_results import require_passed


class JobResultsTests(unittest.TestCase):
    def test_passes_successful_jobs_and_intentional_skips(self):
        with redirect_stdout(StringIO()):
            require_passed({"unit": {"result": "success"}, "ui": {"result": "skipped"}})

    def test_rejects_abandoned_failed_and_unknown_dependency_results(self):
        for result in ("abandoned", "failure", "cancelled", "timed_out", "neutral", "future", "", None):
            with self.subTest(result=result), redirect_stdout(StringIO()):
                with self.assertRaisesRegex(ValueError, "Not passed: unit"):
                    require_passed({"build": {"result": "success"}, "unit": {"result": result}})

    def test_rejects_missing_dependency_results(self):
        for needs in ({}, [], {"unit": {}}, {"unit": None}):
            with self.subTest(needs=needs), self.assertRaises(ValueError):
                require_passed(needs)
