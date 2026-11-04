#!/usr/bin/env python3
"""Copy the canonical vectors to SwiftPM fixtures, or fail CI if the two drift."""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true", help="verify only; do not modify files")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
source = root / "shared/test-vectors/quota-v1.json"
target = root / "macos/Tests/FlowQuotaCoreTests/Fixtures/quota-v1.json"
if args.check:
    if not target.exists() or source.read_bytes() != target.read_bytes():
        parser.exit(1, "Quota fixture drift: run python3 shared/test-vectors/sync-fixtures.py\n")
    print("Quota fixtures match canonical vectors.")
else:
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(source.read_bytes())
    print("Copied canonical quota vectors to SwiftPM fixtures.")
