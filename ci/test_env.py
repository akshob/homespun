# SPDX-License-Identifier: Apache-2.0
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
from uuid import uuid4


@unittest.skipUnless(shutil.which("zsh"), "macOS CI scripts require zsh")
class TestExecutionTests(unittest.TestCase):
    def setUp(self):
        self.checkout = Path(__file__).resolve().parents[1]
        self.root = self.checkout / "ci-results" / f"env-test-{uuid4().hex}"
        self.bin = self.root / "bin"
        self.bin.mkdir(parents=True)
        self.env = {**os.environ, "ROOT": str(self.checkout),
                    "CI_STATE": str(self.root / "state"), "RESULTS": str(self.root),
                    "DD": str(self.root / "derived data"), "GITHUB_ACTIONS": "true",
                    "SIM_SLOTS_DIR": "", "JOB_RECORD": "", "KEEP_SIM": "",
                    "SIM_CALLS": str(self.root / "sim-calls"),
                    "PATH": str(self.bin) + os.pathsep + os.environ["PATH"]}
        fake = self.bin / "xcrun"
        fake.write_text("""#!/usr/bin/env python3
import json, os, sys, time
with open(os.environ["SIM_CALLS"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
command = sys.argv[1:3]
if command == ["simctl", "list"]:
    print(json.dumps({"runtimes": [{"isAvailable": True, "version": "27.2",
        "identifier": "synthetic-runtime", "supportedDeviceTypes": [
        {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"}]}]}))
elif command == ["simctl", "create"]:
    time.sleep(float(os.environ.get("PRESIM_DELAY", "0")))
    print("synthetic-udid")
elif command == ["simctl", "boot"] and os.environ.get("FAIL_BOOT") == "1":
    sys.exit(7)
""")
        fake.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.root)

    def shell(self, script, **environment):
        return subprocess.run(
            ["zsh", "-c", 'source "$ROOT/ci/env.sh"\nNAME=probe\nSIM=synthetic-udid\n' + script],
            env={**self.env, **environment}, text=True, capture_output=True, timeout=15)

    def sim_calls(self):
        path = self.root / "sim-calls"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_xctestrun_keeps_selection_environment_and_exit_status_without_a_project(self):
        products = Path(self.env["DD"]) / "Build/Products"
        products.mkdir(parents=True)
        spec = products / "Homespun_iphonesimulator27.2.xctestrun"
        spec.touch()
        builder = self.bin / "xcodebuild"
        builder.write_text("""#!/usr/bin/env python3
import os, sys
print("\\n".join(sys.argv[1:]))
print("server=" + os.environ.get("TEST_RUNNER_HOMESPUN_SERVER", "missing"))
sys.exit(7)
""")
        builder.chmod(0o755)
        run = self.shell("""
TEST_RUNNER_HOMESPUN_SERVER=synthetic-server test_without_building "$RESULTS/a result.xcresult" \
  -only-testing:HomespunUITests/ServerModeUITests -skip-testing:HomespunUITests/known \
  -retry-tests-on-failure -test-iterations 2
""")
        self.assertEqual(run.returncode, 7, run.stderr)
        self.assertEqual(run.stdout.splitlines(), [
            "test-without-building", "-xctestrun", str(spec), "-destination", "id=synthetic-udid",
            "-resultBundlePath", str(self.root / "a result.xcresult"),
            "-only-testing:HomespunUITests/ServerModeUITests", "-skip-testing:HomespunUITests/known",
            "-retry-tests-on-failure", "-test-iterations", "2", "server=synthetic-server"])

    def test_missing_manifest_fails_ci_but_keeps_local_project_fallback(self):
        script = """
xcodebuild() { print -r -- "$PWD"; printf '%s\\n' "$@"; }
test_without_building "$RESULTS/unit.xcresult" -only-testing:HomespunTests
"""
        ci = self.shell(script)
        self.assertEqual(ci.returncode, 1)
        self.assertIn("has no Homespun simulator .xctestrun", ci.stderr)
        self.assertEqual(ci.stdout, "")
        local = self.shell(script, GITHUB_ACTIONS="")
        self.assertEqual(local.returncode, 0, local.stderr)
        self.assertEqual(local.stdout.splitlines()[0], str(self.checkout / "Apps/Homespun"))
        self.assertIn("-project\nHomespun.xcodeproj\n-scheme\nHomespun\n", local.stdout)

    def test_watch_uses_its_own_manifest_not_the_archived_iphone_tests(self):
        products = Path(self.env["DD"]) / "Build/Products"
        products.mkdir(parents=True)
        (products / "Homespun_iphonesimulator27.2.xctestrun").touch()
        watch = self.root / "HomespunWatch_watchsimulator27.2.xctestrun"
        watch.touch()
        run = self.shell("""
xcodebuild() { printf '%s\\n' "$@"; }
test_without_building "$RESULTS/watch.xcresult" -parallel-testing-enabled NO
""", XCTESTRUN=str(watch))
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("-xctestrun\n" + str(watch) + "\n", run.stdout)
        self.assertNotIn("-project", run.stdout)

    def test_old_app_requires_one_immutable_manifest_and_never_falls_back_to_the_current_app(self):
        current = Path(self.env["DD"]) / "Build/Products"
        current.mkdir(parents=True)
        (current / "Homespun_iphonesimulator27.2.xctestrun").touch()
        products = Path(self.env["DD"]) / "app-b35fc19/Build/Products"
        missing = self.shell('old_app_xctestrun', OLD_APP_PRODUCTS=str(products))
        self.assertEqual(missing.returncode, 1)
        self.assertIn("1.0 app fixture (b35fc19)", missing.stderr)
        self.assertEqual(missing.stdout, "")
        products.mkdir(parents=True)
        spec = products / "Homespun_iphonesimulator27.2.xctestrun"
        spec.touch()
        found = self.shell('old_app_xctestrun', OLD_APP_PRODUCTS=str(products))
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertEqual(found.stdout, str(spec) + "\n")
        forwarded = self.shell("""
xcodebuild() { printf '%s\\n' "$@"; }
XCTESTRUN=$(old_app_xctestrun) || exit 1
test_without_building "$RESULTS/oldapp.xcresult" -only-testing:HomespunUITests/ItemViewerUITests
""", OLD_APP_PRODUCTS=str(products))
        self.assertEqual(forwarded.returncode, 0, forwarded.stderr)
        self.assertIn("-xctestrun\n" + str(spec) + "\n", forwarded.stdout)
        (products / "Homespun_extra_iphonesimulator27.2.xctestrun").touch()
        ambiguous = self.shell('old_app_xctestrun', OLD_APP_PRODUCTS=str(products))
        self.assertEqual(ambiguous.returncode, 1)
        self.assertIn("exactly one", ambiguous.stderr)

    def test_quarantine_override_does_not_read_the_current_app_quarantine(self):
        default = next(line.split()[0] for line in (self.checkout / "ci/quarantine.txt").read_text().splitlines()
                       if line.strip() and not line.startswith("#"))
        old = "HomespunUITests/ServerTabUITests/testIntendedServerChange"
        alternate = self.root / "old app quarantine.txt"
        alternate.write_text(f"{old} #123 intended server behaviour\n")
        run = self.shell('quarantined "$ONLY" "$RESULTS/probe-quarantined.txt"',
                         ONLY=default + "," + old, QUARANTINE=str(alternate))
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout, "-skip-testing:" + old + "\n")
        self.assertEqual((self.root / "probe-quarantined.txt").read_text(),
                         f"{old} #123 intended server behaviour\n")

    def test_strict_selection_requires_every_exact_method_even_when_xcodebuild_succeeds(self):
        viewer = "HomespunUITests/ItemViewerUITests/test1ViewerDetailsAndCompare"
        restore = "HomespunUITests/ServerModeUITests/test3RestoreOriginals"
        passed = "Test Case '-[HomespunUITests.ItemViewerUITests test1ViewerDetailsAndCompare]' passed (1.0 seconds).\n"
        failed = "Test Case '-[HomespunUITests.ServerModeUITests test3RestoreOriginals]' failed (1.0 seconds).\n"
        path = self.root / "strict.log"
        for log, selection, status in [
            (passed + failed.replace("failed", "passed"), viewer + "," + restore, 0),
            (passed + failed, viewer + "," + restore, 0),  # xcodebuild owns test failures.
            (passed, viewer + "," + restore, 1),
            (passed.replace("test1ViewerDetailsAndCompare", "test1ViewerDetailsAndCompareExtra"), viewer, 1),
            ("** TEST EXECUTE SUCCEEDED **\n", viewer, 1),
        ]:
            with self.subTest(log=log, selection=selection):
                path.write_text(log)
                run = self.shell('require_selected_tests_ran "$RESULTS/strict.log" "$ONLY"', ONLY=selection)
                self.assertEqual(run.returncode, status, run.stderr)

    def test_strict_selection_rejects_every_runtime_skip_including_tests_outside_the_selection(self):
        path = self.root / "strict.log"
        path.write_text(
            "Test Case '-[HomespunUITests.ItemViewerUITests test1ViewerDetailsAndCompare]' passed (1.0 seconds).\n"
            "Test Case '-[HomespunUITests.ServerTabUITests test7RePairKeepsTheConfirmedNameAndOneActiveDevice]' skipped (0.0 seconds).\n")
        run = self.shell('require_selected_tests_ran "$RESULTS/strict.log" "$ONLY"',
                         ONLY="HomespunUITests/ItemViewerUITests/test1ViewerDetailsAndCompare")
        self.assertEqual(run.returncode, 1)
        self.assertIn("a 1.0 test skipped", run.stderr)

    def test_strict_selection_exempts_only_explicit_quarantine_and_checks_class_selectors(self):
        viewer = "HomespunUITests/ItemViewerUITests/test1ViewerDetailsAndCompare"
        automatic = "HomespunUITests/ServerModeUITests/test2AutomaticModeBacksUpTheRest"
        path = self.root / "strict.log"
        path.write_text("Test Case '-[HomespunUITests.ItemViewerUITests test1ViewerDetailsAndCompare]' passed (1.0 seconds).\n")
        listing = self.root / "probe-quarantined.txt"
        listing.write_text(automatic + " #123 intended unshipped-feature behaviour\n")
        for selection, status in [
            (viewer + "," + automatic, 0),
            ("HomespunUITests/ItemViewerUITests", 0),
            ("HomespunUITests/CopyFinderUITests", 1),
        ]:
            with self.subTest(selection=selection):
                run = self.shell('require_selected_tests_ran "$RESULTS/strict.log" "$ONLY"', ONLY=selection)
                self.assertEqual(run.returncode, status, run.stderr)
        listing.write_text("")
        run = self.shell('require_selected_tests_ran "$RESULTS/strict.log" "$ONLY"', ONLY=viewer + "," + automatic)
        self.assertEqual(run.returncode, 1)
        # The upgrade phase has its own exclusion list, not the pre-upgrade phase's.
        upgraded = self.root / "probe-upgraded-quarantined.txt"
        upgraded.write_text(automatic + " #123 intended unshipped-feature behaviour\n")
        run = self.shell('require_selected_tests_ran "$RESULTS/strict.log" "$ONLY" "$RESULTS/probe-upgraded-quarantined.txt"',
                         ONLY=viewer + "," + automatic)
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_unit_runs_both_manifests_and_requires_the_release_regression_to_execute(self):
        products = Path(self.env["DD"]) / "Build/Products"
        products.mkdir(parents=True)
        main = products / "Homespun_iphonesimulator27.2.xctestrun"
        scope = products / "HomespunReleaseScope_iphonesimulator27.2.xctestrun"
        main.touch()
        calls = self.root / "build-calls"
        builder = self.bin / "xcodebuild"
        builder.write_text("""#!/usr/bin/env python3
import json, os, sys
spec = sys.argv[sys.argv.index("-xctestrun") + 1]
with open(os.environ["BUILD_CALLS"], "a") as log:
    log.write(json.dumps(spec) + "\\n")
if "HomespunReleaseScope_" in spec and os.environ.get("OMIT_SCOPE_TEST") != "1":
    print("Test Case '-[HomespunTests.ReleaseScopeTests testReleaseDisablesEntryPoints]' passed (0.001 seconds).")
else:
    print("** TEST EXECUTE SUCCEEDED **")
""")
        builder.chmod(0o755)
        for missing, omitted, status in [(False, False, 0), (False, True, 1), (True, False, 1)]:
            with self.subTest(missing=missing, omitted=omitted):
                calls.write_text("")
                if missing:
                    scope.unlink()
                else:
                    scope.touch()
                run = subprocess.run(
                    ["zsh", str(self.checkout / "ci/unit.sh")],
                    env={**self.env, "BUILD_CALLS": str(calls), "XCTESTRUN": "",
                         "OMIT_SCOPE_TEST": "1" if omitted else "0"},
                    text=True, capture_output=True, timeout=15)
                self.assertEqual(run.returncode, status, run.stdout + run.stderr)
                executed = [json.loads(line) for line in calls.read_text().splitlines()]
                self.assertEqual(executed, [str(main)] if missing else [str(main), str(scope)])
                if omitted:
                    self.assertIn("regression did not execute and pass", run.stderr)
                if missing:
                    self.assertIn("missing release-scope test manifest", run.stderr)

    def test_pending_boot_is_claimed_once_without_booting_a_second_simulator(self):
        manifest = Path(self.env["CI_STATE"]) / "presim/iPhone-18-Pro"
        manifest.parent.mkdir(parents=True)
        manifest.with_suffix(".pending").touch()
        producer = subprocess.Popen(
            ["zsh", str(self.checkout / "ci/presim.sh"), "iPhone-18-Pro"],
            env={**self.env, "PRESIM_DELAY": "0.2"},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            claimed = self.shell('new_simulator iPhone-18-Pro "synthetic test"')
            _, errors = producer.communicate(timeout=10)
            self.assertEqual(producer.returncode, 0, errors)
            self.assertEqual(claimed.returncode, 0, claimed.stderr)
            self.assertEqual(claimed.stdout, "synthetic-udid\n")
            self.assertFalse(manifest.exists())
            calls = self.sim_calls()
            self.assertEqual(sum(call[:2] == ["simctl", "create"] for call in calls), 1)
            self.assertEqual(sum(call[:2] == ["simctl", "boot"] for call in calls), 1)
            self.assertTrue(any(call[:2] == ["simctl", "rename"] for call in calls))
            self.assertTrue(any(call[:2] == ["simctl", "bootstatus"] for call in calls))
            fresh = self.shell('new_simulator iPhone-18-Pro "next segment"')
            self.assertEqual(fresh.returncode, 0, fresh.stderr)
            self.assertEqual(sum(call[:2] == ["simctl", "create"] for call in self.sim_calls()), 2)
        finally:
            if producer.poll() is None:
                producer.kill()
                producer.communicate()

    def test_failed_background_boot_cleans_up_and_allows_fresh_creation(self):
        failed = subprocess.run(
            ["zsh", str(self.checkout / "ci/presim.sh"), "iPhone-18-Pro"],
            env={**self.env, "FAIL_BOOT": "1"}, text=True, capture_output=True, timeout=10)
        self.assertEqual(failed.returncode, 7, failed.stderr)
        manifest = Path(self.env["CI_STATE"]) / "presim/iPhone-18-Pro"
        self.assertFalse(manifest.exists())
        self.assertFalse(manifest.with_suffix(".pending").exists())
        self.assertIn(["simctl", "delete", "synthetic-udid"], self.sim_calls())
        fresh = self.shell('new_simulator iPhone-18-Pro "fresh after failure"')
        self.assertEqual(fresh.returncode, 0, fresh.stderr)

    def test_stalled_background_creation_never_boots_a_second_device(self):
        pending = Path(self.env["CI_STATE"]) / "presim/iPhone-18-Pro.pending"
        pending.parent.mkdir(parents=True)
        pending.touch()
        run = self.shell('new_simulator iPhone-18-Pro "synthetic"', PRESIM_TIMEOUT="0")
        self.assertEqual(run.returncode, 1)
        self.assertIn("timed out", run.stderr)
        self.assertEqual(self.sim_calls(), [])

    def test_background_boot_is_disabled_on_shared_simulator_slot_hosts(self):
        run = subprocess.run(
            ["zsh", str(self.checkout / "ci/presim.sh"), "iPhone-18-Pro"],
            env={**self.env, "SIM_SLOTS_DIR": str(self.root / "slots")},
            text=True, capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(self.sim_calls(), [])

    def test_missing_runner_environment_cannot_silently_skip_server_flows(self):
        path = self.root / "flow.log"
        for message, code in [
            ("Test skipped: Set HOMESPUN_SERVER and HOMESPUN_PAIRING_CODE to run against a server.", 1),
            ("Test skipped: Run with ci/later.sh.", 1),
            ("Test skipped: Run on the open iPhone Duo with DUO_POSES=1 and a test server.", 1),
            ("Test skipped: Stop the server and set HOMESPUN_UNREACHABLE=1 to run this.", 0),
            ("Test Case 'flow' passed.", 0),
        ]:
            with self.subTest(message=message):
                path.write_text(message)
                run = self.shell('require_test_environment "$RESULTS/flow.log"')
                self.assertEqual(run.returncode, code, run.stderr)

    def test_first_device_matches_each_distinct_lane_kind_and_rejects_unknown(self):
        for lane, device in [("quick-duo", "iPhone-Duo"), ("demo", "iPhone-18-Pro"),
                             ("oldserver", "iPhone-18-Pro"),
                             ("oldapp", "iPhone-18-Pro"), ("oldapp-copies", "iPhone-18-Pro"),
                             ("oldapp-upgrade", "iPhone-18-Pro"),
                             ("watch", "Apple-Watch-Series-12-46mm")]:
            run = self.shell(f'zsh "$ROOT/ci/lane.sh" --first-device {lane}')
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout.strip(), device)
        unknown = self.shell('zsh "$ROOT/ci/lane.sh" --first-device unknown')
        self.assertNotEqual(unknown.returncode, 0)


if __name__ == "__main__":
    unittest.main()
