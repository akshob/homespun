# SPDX-License-Identifier: Apache-2.0
import copy
import unittest

from check_wake_project import check


class WakeProjectTests(unittest.TestCase):
    def project(self, enabled):
        entitlements = "HomespunWake.entitlements" if enabled else "Homespun.entitlements"
        objects = {"target": {"isa": "PBXNativeTarget", "name": "Homespun", "buildConfigurationList": "configs"},
                   "configs": {"buildConfigurations": ["Debug", "Profile", "Release"]}}
        for name in objects["configs"]["buildConfigurations"]:
            settings = {"CODE_SIGN_ENTITLEMENTS": "Homespun/Resources/" + entitlements}
            if enabled:
                settings["HOMESPUN_APNS_ENVIRONMENT"] = "production" if name == "Release" else "development"
            objects[name] = {"name": name, "buildSettings": settings}
        return {"objects": objects}

    def test_explicit_overlay_requires_remote_mode_and_matching_push_environments(self):
        info = {"HomespunWakeRelayURL": "https://wake.example.invalid",
                "UIBackgroundModes": ["processing", "remote-notification"]}
        project = self.project(True)
        check(info, project, wake_url=info["HomespunWakeRelayURL"])
        wrong = copy.deepcopy(project)
        wrong["objects"]["Release"]["buildSettings"]["HOMESPUN_APNS_ENVIRONMENT"] = "development"
        with self.assertRaises(ValueError):
            check(info, wrong, wake_url=info["HomespunWakeRelayURL"])

    def test_returning_to_default_cannot_leave_the_relay_or_push_entitlements_enabled(self):
        info = {"HomespunWakeRelayURL": "", "UIBackgroundModes": ["processing"]}
        check(info, self.project(False), wake_url="")
        with self.assertRaises(ValueError):
            check(info, self.project(True), wake_url="")
        with self.assertRaises(ValueError):
            check({"HomespunWakeRelayURL": "https://wake.example.invalid",
                   "UIBackgroundModes": ["processing", "remote-notification"]}, self.project(False), wake_url="")
