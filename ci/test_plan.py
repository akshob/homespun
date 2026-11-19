# SPDX-License-Identifier: Apache-2.0
import unittest

from plan import FULL, QUICK, plan


class WatchPlanTests(unittest.TestCase):
    def test_watch_changes_add_regression_to_ready_pr(self):
        for path in ("Apps/Homespun/HomespunWatch/WatchStatusView.swift",
                     "Apps/Homespun/HomespunWatchUITests/WatchStatusUITests.swift",
                     "Apps/Homespun/Widgets/WidgetStyle.swift",
                     "Apps/Homespun/Shared/StatusSnapshot.swift",
                     "Apps/Homespun/project.yml", "ci/watch.sh"):
            with self.subTest(path=path):
                result = plan({"MODE": "pr"}, [path])
                self.assertEqual(result["ui"], ["quick", "quick-duo", "watch"])
        self.assertEqual(QUICK, ["quick", "quick-duo"])

    def test_draft_keeps_build_only(self):
        result = plan({"MODE": "pr", "DRAFT": "true"}, ["Apps/Homespun/HomespunWatch/WatchStatusView.swift"])
        self.assertTrue(result["app"])
        self.assertEqual(result["ui"], [])

    def test_unrelated_app_change_keeps_quick_runs(self):
        result = plan({"MODE": "pr"}, ["Apps/Homespun/Homespun/App/HomespunApp.swift"])
        self.assertEqual(result["ui"], ["quick", "quick-duo"])

    def test_manual_watch_does_not_run_unrelated_suites(self):
        result = plan({"MODE": "manual", "UI_INPUT": "watch"}, [])
        self.assertTrue(result["app"])
        self.assertEqual(result["ui"], ["watch"])
        for key in ("server", "telemetry", "site", "package"):
            self.assertFalse(result[key], key)

    def test_extended_and_manual_full_include_watch(self):
        self.assertIn("watch", FULL)
        for env in ({"MODE": "main"}, {"MODE": "manual", "UI_INPUT": "full"}):
            with self.subTest(env=env):
                self.assertIn("watch", plan(env, ["Apps/Homespun/project.yml"])["ui"])


class PackagePlanTests(unittest.TestCase):
    def test_package_retry_does_not_repeat_passing_checks(self):
        result = plan({"MODE": "manual", "UI_INPUT": "package"}, [])
        self.assertTrue(result["package"])
        self.assertEqual(result["ui"], [])
        for key in ("server", "telemetry", "site", "app"):
            self.assertFalse(result[key], key)


class TargetedUIPlanTests(unittest.TestCase):
    def test_manual_duo_open_does_not_repeat_the_full_matrix(self):
        result = plan({"MODE": "manual", "UI_INPUT": "duo-open"}, [])
        self.assertTrue(result["app"])
        self.assertEqual(result["ui"], ["duo-open"])
        for key in ("server", "telemetry", "site", "package"):
            self.assertFalse(result[key], key)

    def test_trait_probe_uses_only_build_and_probe_job(self):
        result = plan({"MODE": "manual", "UI_INPUT": "custom", "RUNS_INPUT": "probe probe"}, [])
        self.assertTrue(result["app"])
        self.assertFalse(result["unit"])
        self.assertEqual(result["ui"], ["probe"])
        for key in ("server", "telemetry", "site", "package"):
            self.assertFalse(result[key], key)

    def test_custom_run_rejects_empty_unknown_and_shell_input(self):
        for runs in ("", "unknown", "probe;echo", "probe $(command)"):
            with self.subTest(runs=runs), self.assertRaises(ValueError):
                plan({"MODE": "manual", "UI_INPUT": "custom", "RUNS_INPUT": runs}, [])

    def test_recording_uses_unit_without_unrelated_jobs(self):
        for mode in ("record", "record-missing"):
            with self.subTest(mode=mode):
                result = plan({"MODE": "manual", "UI_INPUT": "none", "SNAPSHOTS_INPUT": mode}, [])
                self.assertTrue(result["app"])
                self.assertTrue(result["unit"])
                self.assertEqual(result["ui"], [])
                for key in ("server", "telemetry", "site", "package"):
                    self.assertFalse(result[key], key)


if __name__ == "__main__":
    unittest.main()
