"""Build and run the local UIKit fixture app on an existing macOS CI simulator.

This executes cache regression against explicit fake SDK events, not the Focus
app or live websites. Simulator selection is discovered from the installed SDK.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import uuid


def run(args, capture=False):
    result = subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def main():
    root = Path(__file__).resolve().parents[1]
    output = root / "build" / "IconRegression.app"
    output.mkdir(parents=True, exist_ok=True)
    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], True)
    listing = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "--json"], True))
    candidates = []
    for runtime, devices in listing["devices"].items():
        if ".iOS-" not in runtime:
            continue
        for device in devices:
            if device.get("isAvailable") and "iPhone" in device.get("name", ""):
                candidates.append((runtime, device["name"], device))
    if not candidates:
        raise RuntimeError("No available iOS iPhone simulator; icon regression was not executed")
    candidates.sort(key=lambda entry: entry[0], reverse=True)
    device = candidates[0][2]
    identifier = device["udid"]
    created_boot = device.get("state") != "Booted"
    if created_boot:
        run(["xcrun", "simctl", "boot", identifier])
    run(["xcrun", "simctl", "bootstatus", identifier, "-b"])
    bundle = "local.focusdm.icon-regression.r" + uuid.uuid4().hex
    info = {
        "CFBundleIdentifier": bundle, "CFBundleExecutable": "IconRegression",
        "CFBundleName": "IconRegression", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "14.0", "LSRequiresIPhoneOS": True,
        "UIDeviceFamily": [1], "UILaunchScreen": {},
    }
    (output / "Info.plist").write_bytes(plistlib.dumps(info))
    command = ["xcrun", "--sdk", "iphonesimulator", "clang", "-isysroot", sdk,
               "-fobjc-arc", "-fblocks", "-DFDM_TESTING=1", "-Wall", "-Wextra", "-Isrc",
               "-mios-simulator-version-min=14.0", "-framework", "UIKit", "-framework", "Foundation",
               "-framework", "QuartzCore", "-framework", "CoreGraphics", "-framework", "ImageIO", "-framework", "QuickLook",
               "-framework", "WebKit", "-framework", "Security", "-lsqlite3"]
    command.extend(str(path.relative_to(root)) for path in sorted((root / "src").glob("*.m")))
    command.extend(["tests/icons_regression.m", "tests/forms_regression.m",
                    "tests/settings_regression.m", "tests/download_ui_regression.m",
                    "tests/page_navigation_regression.m",
                    "tests/icons_app_main.m", "-o", str(output / "IconRegression")])
    run(command)
    run(["codesign", "--force", "--sign", "-", str(output)])
    try:
        run(["xcrun", "simctl", "install", identifier, str(output)])
        run(["xcrun", "simctl", "launch", identifier, bundle])
        container = Path(run(["xcrun", "simctl", "get_app_container", identifier, bundle, "data"], True))
        result_path = container / "Documents" / "regression-result.txt"
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if result_path.is_file():
                result = result_path.read_text(encoding="utf-8")
                print(f"UIKit icon regression result: {result}")
                if result != "PASS":
                    raise RuntimeError(result)
                return 0
            time.sleep(0.2)
        raise TimeoutError("UIKit icon regression result was not produced within 90 seconds")
    finally:
        # Only this CI-created fixture app and boot state are managed.
        subprocess.run(["xcrun", "simctl", "terminate", identifier, bundle], check=False)
        if created_boot:
            subprocess.run(["xcrun", "simctl", "shutdown", identifier], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
