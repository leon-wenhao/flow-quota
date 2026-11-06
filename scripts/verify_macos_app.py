"""Audit files and signed executables before placing a release app in a DMG.

Apple codesign, lipo and vtool inspect local files only. This does not launch
sampling, test Gatekeeper approval, or prove Intel runtime compatibility.
"""
import argparse
from pathlib import Path
import plistlib
import subprocess

FILES = {
    "Contents/Info.plist", "Contents/MacOS/FlowQuota", "Contents/MacOS/FlowQuotaAgent",
    "Contents/Library/LaunchAgents/local.flowquota.agent.plist",
    "Contents/Resources/FlowQuota.icns", "Contents/_CodeSignature/CodeResources",
}


def verify(app, arch, version, build):
    app = Path(app)
    paths = list(app.rglob("*"))
    if any(path.is_symlink() for path in paths):
        raise ValueError("Unexpected symlink inside the application")
    if {str(path.relative_to(app)) for path in paths if path.is_file()} != FILES:
        raise ValueError("Application contains missing or unexpected files")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info["CFBundleShortVersionString"], info["CFBundleVersion"], info["LSMinimumSystemVersion"]) != (version, build, "14.0"):
        raise ValueError("Application version/build/minimum system mismatch")
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
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    print("Release app audit passed: " + arch)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--arch", required=True, choices=("arm64", "x86_64"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    verify(args.app, args.arch, args.version, args.build)
