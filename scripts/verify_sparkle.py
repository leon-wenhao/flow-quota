"""Audit the exact Sparkle 2.10.1 distribution; do not admit arbitrary frameworks.

The generated manifest includes the original vendor signatures. The outer app is
ad-hoc signed; Sparkle's nested signed bundles remain byte-for-byte unmodified.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

MANIFEST = Path(__file__).resolve().parents[1] / "macos/Configuration/sparkle-files.json"


def verify(framework):
    framework = Path(framework)
    expected = json.loads(MANIFEST.read_text())
    paths = {str(p.relative_to(framework)): p for p in framework.rglob("*")
             if p.is_file() or p.is_symlink()}
    if set(paths) != set(expected):
        raise ValueError("Sparkle contains missing or unexpected files")
    for name, entry in expected.items():
        path = paths[name]
        if "link" in entry:
            if not path.is_symlink() or str(path.readlink()) != entry["link"]:
                raise ValueError("Unexpected Sparkle symlink: " + name)
            if not path.resolve().is_relative_to(framework.resolve()):
                raise ValueError("Sparkle symlink escapes framework")
        elif path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("Modified Sparkle file: " + name)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(framework)], check=True)


if __name__ == "__main__":
    verify(sys.argv[1])
