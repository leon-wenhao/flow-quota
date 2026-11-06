# Shared quota vectors

`quota-v1.json` is the canonical, platform-independent schema v1 fixture for Flow Quota.
See `docs/quota-rules.md` for field conventions and complete behavior. Bytes are decimal
Int64 **strings**, not JSON numbers; null denotes absence. Upload/download are already scoped to ONE accounting category, never a combined
all-network sum. Ordinary paths now evaluate their own separately configured rule;
no rule means no reminder. `expensive` is a system cost signal,
not proof of a phone hotspot; it shares the daily budget with `hotspot`. Gregorian date keys are `yyyy-MM-dd` in the supplied
IANA time zone. Notifications dedup on category/app/day/rule revision/kind. Legacy vectors omit
category and default to metered; TrafficCategoryTests covers cross-category dedup.

Edit this file first, then run from the repository root:

```sh
python3 shared/test-vectors/sync-fixtures.py
python3 shared/test-vectors/sync-fixtures.py --check
swift test --package-path macos --filter FlowQuotaCoreTests
```

The script mirrors the canonical JSON into `macos/Tests/FlowQuotaCoreTests/Fixtures/` for
SwiftPM's existing `.copy("Fixtures")` resource. Both `--check` and the Swift byte equality
test reject drift. Windows should read the canonical JSON when its quota domain is added.
The tests simulate domain inputs; they do not emulate or assert a working network engine.
