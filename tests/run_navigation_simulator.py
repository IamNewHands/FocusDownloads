"""Build and run the navigation regression app on an installed iOS simulator.

This executes the real ``src/FDMNavigation``, ``src/FDMEngine`` and
``src/FDMWebKitDownloads`` against a loopback HTTP server: a POST navigation that
answers with ``Content-Disposition: attachment`` must become a real WKDownload and
reach the server exactly once. It is not the Focus app and does not prove device
acceptance.

The fixture server picks its own port; the app receives it through Info.plist as
``TEST_ORIGIN``. App Transport Security is limited to local networking plus an
exception for 127.0.0.1, so no other cleartext traffic is enabled.
"""
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time
import uuid

DEADLINE_SECONDS = 180


def run(args, capture=False):
    result = subprocess.run(args, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def pick_device():
    listing = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "--json"], True))
    candidates = []
    for runtime, devices in listing["devices"].items():
        if ".iOS-" not in runtime:
            continue
        for device in devices:
            if device.get("isAvailable") and "iPhone" in device.get("name", ""):
                candidates.append((runtime, device))
    if not candidates:
        raise RuntimeError("No available iOS iPhone simulator; navigation regression was not executed")
    candidates.sort(key=lambda entry: entry[0], reverse=True)
    return candidates[0][1]


def start_server(root, work):
    log_path = work / "requests.json"
    ready_path = work / "server-port.txt"
    process = subprocess.Popen(
        [sys.executable, str(root / "tests" / "navigation_fixture_server.py"),
         "--log", str(log_path), "--ready", str(ready_path)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if ready_path.is_file():
            port = ready_path.read_text(encoding="utf-8").strip()
            if port.isdigit():
                return process, int(port), log_path
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout else ""
            raise RuntimeError(f"fixture server exited early: {output}")
        time.sleep(0.05)
    process.kill()
    raise TimeoutError("fixture server did not bind a port within 20 seconds")


def read_requests(log_path):
    try:
        return json.loads(log_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def main():
    root = Path(__file__).resolve().parents[1]
    work = root / "build" / ("navigation-regression-" + uuid.uuid4().hex)
    work.mkdir(parents=True, exist_ok=False)
    output = work / "NavigationRegression.app"
    output.mkdir(parents=True, exist_ok=True)

    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], True)
    device = pick_device()
    identifier = device["udid"]
    created_boot = device.get("state") != "Booted"
    server = None
    bundle = "local.focusdm.navigation-regression.r" + uuid.uuid4().hex
    try:
        server, port, request_log = start_server(root, work)
        origin = f"http://127.0.0.1:{port}"
        print(f"Navigation fixture origin: {origin}")

        info = {
            "CFBundleIdentifier": bundle, "CFBundleExecutable": "NavigationRegression",
            "CFBundleName": "NavigationRegression", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": "14.0", "LSRequiresIPhoneOS": True,
            "UIDeviceFamily": [1], "UILaunchScreen": {},
            "TEST_ORIGIN": origin,
            # Only local cleartext is permitted; every other host still needs TLS.
            "NSAppTransportSecurity": {
                "NSAllowsLocalNetworking": True,
                "NSExceptionDomains": {
                    "127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True},
                },
            },
        }
        (output / "Info.plist").write_bytes(plistlib.dumps(info))

        command = [
            "xcrun", "--sdk", "iphonesimulator", "clang", "-isysroot", sdk,
            "-fobjc-arc", "-fblocks", "-DFDM_TESTING=1", "-Wall", "-Wextra", "-Isrc",
            "-mios-simulator-version-min=14.0",
            "-framework", "UIKit", "-framework", "Foundation", "-framework", "WebKit",
            "-framework", "QuickLook", "-framework", "Security", "-framework", "ImageIO",
            "-framework", "CoreGraphics", "-framework", "QuartzCore",
        ]
        # Every shipped module except FocusDM.m: its constructor installs hooks on the real host
        # classes, which do not exist in this fixture.
        sources = sorted(
            str(path.relative_to(root))
            for path in (root / "src").glob("*.m")
            if path.name != "FocusDM.m"
        )
        command += sources
        command += [
            "-lsqlite3",
            "tests/navigation_regression.m", "tests/navigation_app_main.m",
            "-o", str(output / "NavigationRegression"),
        ]
        run(command)
        run(["codesign", "--force", "--sign", "-", str(output)])

        if created_boot:
            run(["xcrun", "simctl", "boot", identifier])
        run(["xcrun", "simctl", "bootstatus", identifier, "-b"])

        run(["xcrun", "simctl", "install", identifier, str(output)])
        run(["xcrun", "simctl", "launch", identifier, bundle])
        container = Path(run(["xcrun", "simctl", "get_app_container", identifier, bundle, "data"], True))
        result_path = container / "Documents" / "regression-result.txt"

        deadline = time.monotonic() + DEADLINE_SECONDS
        result = None
        while time.monotonic() < deadline:
            if result_path.is_file():
                text = result_path.read_text(encoding="utf-8").strip()
                if text:
                    result = text
                    break
            time.sleep(0.25)
        requests = read_requests(request_log)
        print(f"Fixture requests observed: {json.dumps(requests, ensure_ascii=False)}")
        if result is None:
            raise TimeoutError(
                f"navigation regression result was not produced within {DEADLINE_SECONDS} seconds; "
                f"fixture requests: {json.dumps(requests, ensure_ascii=False)}"
            )
        print(f"Navigation regression result: {result}")
        if result != "PASS":
            raise RuntimeError(result)
        return 0
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", identifier, bundle], check=False)
        if created_boot:
            subprocess.run(["xcrun", "simctl", "shutdown", identifier], check=False)
        if server is not None and server.poll() is None:
            server.send_signal(signal.SIGTERM)
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()


if __name__ == "__main__":
    raise SystemExit(main())
