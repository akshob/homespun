# SPDX-License-Identifier: Apache-2.0
import unittest

from plan import FULL, QUICK, plan


class WatchPlanTests(unittest.TestCase):
    def test_watch_changes_add_regression_to_ready_pr(self):
        for path in ("Apps/Homespun/HomespunWatch/WatchStatusView.swift",
                     "Apps/Homespun/HomespunWatchUITests/WatchStatusUITests.swift",
                     "Apps/Homespun/Widgets/WidgetStyle.swift",
                     "Apps/Homespun/Shared/StatusSnapshot.swift",
                     "Apps/Homespun/project.yml", "Apps/Homespun/project-features.yml",
                     "Apps/Homespun/ReleaseFeatures.xcconfig", "Apps/Homespun/scripts/generate-project.sh",
                     "ci/watch.sh"):
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
    def test_old_server_fixture_is_extended_only(self):
        self.assertIn("oldserver", FULL)
        self.assertNotIn("oldserver", QUICK)
        for draft in ("true", "false"):
            result = plan({"MODE": "pr", "DRAFT": draft}, ["Apps/Homespun/HomespunUITests/OldServerUITests.swift"])
            self.assertNotIn("oldserver", result["ui"])

    def test_manual_copy_recovery_keeps_server_contracts_without_unrelated_ui(self):
        result = plan({"MODE": "manual", "UI_INPUT": "copies"}, [])
        self.assertEqual(result["ui"], ["copies"])
        for key in ("server", "package", "app"):
            self.assertTrue(result[key], key)
        for key in ("telemetry", "site"):
            self.assertFalse(result[key], key)

    def test_manual_focused_ui_does_not_repeat_the_full_matrix(self):
        for choice in (run for run in FULL if run != "copies"):
            with self.subTest(choice=choice):
                result = plan({"MODE": "manual", "UI_INPUT": choice}, [])
                self.assertTrue(result["app"])
                self.assertEqual(result["ui"], [choice])
                for key in ("server", "telemetry", "site", "package"):
                    self.assertFalse(result[key], key)


if __name__ == "__main__":
    unittest.main()
