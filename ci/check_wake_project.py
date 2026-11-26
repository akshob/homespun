# SPDX-License-Identifier: Apache-2.0
"""Verify the optional wake overlay, then restore and verify the ordinary generated project."""
import json
import os
from pathlib import Path
import plistlib
import subprocess


def check(info, project, *, wake_url):
    expected_modes = ["processing", "remote-notification"] if wake_url else ["processing"]
    if info.get("HomespunWakeRelayURL") != wake_url or info.get("UIBackgroundModes") != expected_modes:
        raise ValueError("Wake Info.plist does not match the explicitly selected build scope.")
    if info.get("HomespunWakePushEnvironment") != ("$(HOMESPUN_APNS_ENVIRONMENT)" if wake_url else ""):
        raise ValueError("Wake environment must come from the same setting as the signed entitlement.")
    objects = project["objects"]
    targets = [value for value in objects.values()
               if value.get("isa") == "PBXNativeTarget" and value.get("name") == "Homespun"]
    if len(targets) != 1:
        raise ValueError("Cannot identify the iPhone app target.")
    configurations = objects[targets[0]["buildConfigurationList"]]["buildConfigurations"]
    for identifier in configurations:
        configuration = objects[identifier]
        settings = configuration["buildSettings"]
        expected = "Homespun/Resources/HomespunWake.entitlements" if wake_url else "Homespun/Resources/Homespun.entitlements"
        if settings.get("CODE_SIGN_ENTITLEMENTS") != expected:
            raise ValueError("Unexpected iPhone entitlements file.")
        if wake_url:
            environment = "production" if configuration["name"] == "Release" else "development"
            if settings.get("HOMESPUN_APNS_ENVIRONMENT") != environment:
                raise ValueError("Push environment does not match the bundle's build configuration.")


def main():
    root = Path(__file__).resolve().parents[1]
    app = root / "Apps/Homespun"
    example = "https://wake.example.invalid"
    for url in (example, ""):
        env = dict(os.environ, HOMESPUN_WAKE_RELAY_URL=url)
        subprocess.run(["zsh", str(app / "scripts/generate-project.sh"), "--testing"],
                       env=env, cwd=app, check=True)
        with (app / "Homespun/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        project = json.loads(subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", str(app / "Homespun.xcodeproj/project.pbxproj")]))
        check(info, project, wake_url=url)
    print("Explicit wake overlay and default no-enrollment project verified.")


if __name__ == "__main__":
    main()
