"""Audit files and signed executables before placing a release app in a DMG.

Apple codesign, lipo and vtool inspect local files only. This does not launch
sampling, test Gatekeeper approval, or prove Intel runtime compatibility.
"""
import argparse
import hashlib
from pathlib import Path
import plistlib
import subprocess
from verify_sparkle import verify as verify_sparkle

FILES = {
    "Contents/Info.plist", "Contents/MacOS/FlowQuota", "Contents/MacOS/FlowQuotaAgent",
    "Contents/Library/LaunchAgents/local.flowquota.agent.plist",
    "Contents/Resources/FlowQuota.icns", "Contents/Resources/Sparkle-LICENSE.txt", "Contents/_CodeSignature/CodeResources",
}


def verify(app, arch, version, build):
    app = Path(app)
    framework = app / "Contents/Frameworks/Sparkle.framework"
    verify_sparkle(framework)
    paths = [path for path in app.rglob("*") if not path.is_relative_to(framework)]
    if any(path.is_symlink() for path in paths):
        raise ValueError("Unexpected symlink inside the application")
    if {str(path.relative_to(app)) for path in paths if path.is_file()} != FILES:
        raise ValueError("Application contains missing or unexpected files")
    if hashlib.sha256((app / "Contents/Resources/Sparkle-LICENSE.txt").read_bytes()).hexdigest() != "389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe":
        raise ValueError("Sparkle license differs from pinned distribution")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info["CFBundleShortVersionString"], info["CFBundleVersion"], info["LSMinimumSystemVersion"]) != (version, build, "14.0"):
        raise ValueError("Application version/build/minimum system mismatch")
    if info["SUFeedURL"] != "https://github.com/leon-wenhao/flow-quota/releases/latest/download/appcast-" + arch + ".xml":
        raise ValueError("Updater architecture/feed mismatch")
    expected_key = plistlib.loads((Path(__file__).resolve().parents[1] / "macos/Configuration/Info.plist").read_bytes())["SUPublicEDKey"]
    if info.get("SUPublicEDKey") != expected_key or not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("Missing updater authentication")
    # App-owned informational probes are allowed; Sparkle's UI scheduler stays off.
    for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling"):
        if info.get(key) is not False:
            raise ValueError("Sparkle UI scheduling, automatic installation and profile collection must be disabled")
    for name in ("FlowQuota", "FlowQuotaAgent"):
        binary = app / "Contents/MacOS" / name
        subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
        actual = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
        if actual != arch:
            raise ValueError("Executable architecture mismatch")
        load_commands = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
        if "minos 14.0" not in load_commands:
            raise ValueError("Executable minimum macOS mismatch")
        # Public binaries must not carry local source/debug paths.
        if b"/Users/" in binary.read_bytes():
            raise ValueError("Executable contains a local user path; inspect debug symbols")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("Release app audit passed: " + arch)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--arch", required=True, choices=("arm64", "x86_64"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    verify(args.app, args.arch, args.version, args.build)
