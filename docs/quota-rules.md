# Quota domain and shared vectors

> Reminder-only iteration, 2026-11-05: `.blocked` remains a legacy domain/persistence threshold key for compatibility. It never means a connection was blocked by this iteration. Monitoring readiness and notification delivery are independent, see tasks/005-reminder-monitor.md.

## Current network scope (2026-11-05)

`NetworkState.expensive` means a satisfied `NWPath` with `isExpensive`; it automatically
counts observed increments. This cost signal does not confirm a phone hotspot, device or
carrier. `.hotspot` remains an explicit manual mark. `NetworkState.countsTraffic` is true
for both states, false for `.ordinary` (no automatic counting) and `.unknown` (unavailable
network state). UI manual controls remain available for ordinary/unknown when the service
permits changes; expensive hides the redundant mark action and hotspot retains cancellation.

Both counted states share one app/current-local-day usage total and reminder budget. Path
or mark changes rebuild the sampling baseline without clearing persisted usage, granting a
fresh allowance or backfilling unknown intervals. Application budgets retain their existing
structure; schema v3 separately stores independent daily interface totals. A rule
ACK confirms persistence; reaching a threshold only requests a reminder, never blocking.
Already observed daily usage remains visible after leaving a counted path when sampling
and the snapshot remain valid.

Apple's API defines the cost signal: https://developer.apple.com/documentation/network/nwpath/isexpensive.
Automatic inclusion in this budget is project policy, not hotspot identity detection.
The headline and menu total use only the independently persisted interface meter; application
attribution may overlap and is never added together to fill a missing interface total.
Application reminders continue to use application attribution, not the interface ledger.
Both ledgers include expensive/manual-hotspot observed intervals for the current local day.
A missing interface row is unknown; an explicit baseline can establish a valid zero.

Current validation: 164 tests passed (Core 29, Store 39, Platform 48, App 37, Agent 11).
Both architecture builds and strict signatures pass. This iteration uses simulated counters,
injected system calls and temporary databases only; no hotspot traffic experiments or
installed-app interface checks were performed. Prior live results in `implementation-status.md`
are historical application-sampler evidence, not proof of the new interface meter or billing accuracy.

## Domain implementation background

Historical baseline: 2026-11-04. Swift tools 6.0 / macOS 14 minimum, verified with Apple Swift 6.4.2,
macOS SDK 27.2, arm64 macOS 27.2. These are domain calculations and an **in-memory**
reservation model. They do not install a filter, observe traffic, persist budgets, or prove
real network enforcement/readiness. The Store's durable lease ledger is a separate component.
No signing, deployment, entitlement or security configuration is changed here.

## Public entry points

All implementation files are in `macos/Sources/FlowQuotaCore/`:

| File / API | Responsibility |
| --- | --- |
| `DecimalBytes.swift`: `DecimalBytes.parse(_:unit:)` | Exact nonnegative integer bytes from decimal `.MB` / `.GB` text. |
| `LocalDay.swift`: `LocalDay.key(for:in:)`, `isValidKey(_:)` | Explicit-zone Gregorian `yyyy-MM-dd` keys and shared validation. |
| `LocalDay.swift`: `QuotaIdentity` | Validated app key + day + positive rule revision; safe Codable decoding. |
| `QuotaEvaluation.swift`: `QuotaEvaluator.evaluate(rule:usage:network:)` | Pure scope, availability, threshold and limit decisions. |
| `QuotaEvaluation.swift`: `QuotaTransitions.evaluate(...)` | Pure notification proposals against persisted dedup keys. |
| `QuotaBudgetLedger.swift`: `QuotaBudgetLedger` | One app/day's actor-isolated grants and final settlement. |

Base models are in `Models.swift` and `ServiceModels.swift`; the latter now includes the
network scope contract above. `QuotaRule`
already validates positive optional limits, warning percentages 1...99, and positive versions.
`DailyUsage.totalBytes` already saturates arithmetic overflow. Evaluator rejects either
negative component before using that total; missing counters are represented by `nil`.

## Decimal input and evaluation semantics

1 MB = 1,000,000 bytes; 1 GB = 1,000,000,000 bytes. Parsing uses checked integer
multiply/add only, with no `Double`, locale parsing, rounding, or floating conversion.
Surrounding whitespace is accepted; ASCII digits and at most one decimal point with digits
on both sides are required. Signs, exponent notation, commas and Unicode digits are rejected.
Precision below one byte is rejected unless excess fractional digits are all zero.
Zero is valid for conversion, but cannot become a finite QuotaRule limit. All persisted or
interchanged byte counts use nonnegative Int64 values (maximum 9,223,372,036,854,775,807).

`ordinaryNetwork` and `unknownNetwork` never automatically consume the shared budget. Unknown is an explicit
scope uncertainty, not a claim that unrestricted traffic is safe or protection is ready.
For expensive or manually marked hotspot scope, missing usage yields `usageUnavailable`, including for an unlimited app;
known usage without a finite rule yields `unlimited`. `countsTraffic` expresses scope only,
not proof of installed metering. The integration must handle readiness/errors independently.

Finite rules compare upload + download with a threshold of
`ceil(limitBytes * warningPercent / 100)`. The implementation splits quotient and remainder
to avoid overflow. Equality at the threshold warns; equality at the cap blocks, taking
precedence over warning. Remaining bytes clamp to zero. Tiny limits can have their threshold
at the cap, producing a direct transition to blocked. Evaluation never changes counters;
leaving hotspot scope releases the restriction while retaining the same day's usage.
A raised cap can permit subsequent reconnection; a lowered cap may immediately block.

## Dates, wake and changes

`LocalDay.key(for:in:)` requires a `Date` and an explicit Foundation `TimeZone`; it does not
read the current time, calendar, locale or global default zone. It uses a Gregorian calendar,
not the user's preferred calendar, and rejects unsupported/nonfinite dates outside CE
0001...9999. `isValidKey` checks fixed-width ASCII format, month lengths and leap years.
Store and other consumers should reuse this validator rather than maintain parallel rules.

The processing owner must recompute the key on each event, particularly after sleep, clock
changes, zone changes and path changes. There is no midnight timer or 86,400-second day
assumption. DST days can be 23/25 hours. The time-zone identifier is not a separate budget
bucket: two zones yielding the same local date do not create two allowances. A connection
crossing day/network boundaries must process later chunks under the new context, not its
connection-open date. Returning to a prior local date requires the service's trusted
same-day state; this domain does not implement storage, date cleanup or anti-tampering.

## Warning/block dedup and rule revisions

`QuotaNotificationKey` contains `QuotaIdentity` and `.warning` / `.blocked`. The first
eligible warning or block whose key is absent is proposed once; calling again with the
acknowledged key suppresses it. A direct jump to blocked proposes only a block. A recorded
block suppresses a later warning in that identity. Ordinary/unknown paths, unlimited rules,
and unavailable usage produce no notification. New day/app/revision keys are independent;
an edit must use an increasing revision and may cause a fresh warning/block evaluation.
Transitions check that supplied usage belongs to the exact app/day and the rule's revision
matches the identity. Reconnect/restart can recompute from counters and restored keys,
without keeping a previous UI status in memory.

The function only proposes keys. The service must serialize notification claiming and
persist dedup state; parallel callers given the same old set will propose the same key.
A storage acknowledgement plus OS notification delivery is not made atomic here. Exact
once delivery across a crash, denied notification permission, and notification outbox/retry
policy remain integration work. Do not record success merely because this function returns.

## Atomic reservation model

Construct one ledger per stable app/day with a trusted restored `usedBytes` total and a rule.
All connections for that app/day must share it. `reserve(bytes:)` checks and debits in one
synchronous actor turn, with no `await` between them; it returns a single-use token for up to
the requested bytes, a partial final grant, or `nil` when no capacity remains. Requests must
be positive. Pending tokens have a configurable count bound (default 1,024); reaching it
throws without changing balances. Unlimited rules still respect Int64 representability.

For an unchanged finite rule, `used + reserved <= cap`. If restored usage already exceeds
that cap, no new grant is issued. `reconcile(token, consumedBytes:)` is FINAL cumulative
actual consumption in `0...grantedBytes`, not an incremental report. It transfers actuals
to used and releases only proven unused bytes. `release` is settlement with zero actuals
and requires proof that no consumed/in-flight bytes belong to that token. Disconnect,
cancellation, deadline expiry or a missing report does not prove this. There is **no automatic
expiration/refund**. `forfeit` conservatively charges the full grant when actuals are unknown.
Over-grant actuals are an explicit error and remain unresolved/charged; never truncate them
silently or treat a provider contract violation as successful enforcement.

A token's identity is immutable, including its issue revision. Duplicate, unknown, forged
or foreign-ledger reports fail before mutation. Completed tokens are removed; a repeated
receipt cannot free newer grants. No unbounded receipt/tombstone history is kept.
`updateRule` accepts only increasing revisions or an exactly identical idempotent retry.
It preserves used bytes and all pending old-version holds, even through unlimited/limited
switches. Old receipts settle only their original held amount in the original ledger.
They cannot settle into a replacement/new-day ledger or cancel unrelated current grants.
After lowering a cap, existing liabilities can exceed the new cap; new grants remain denied
until sufficient capacity exists. `isCurrent(token)` becomes false after revision changes
or settlement, but does not check time, path or readiness.

Real integration must revoke/revalidate old grants before processing chunks after a rule,
day or network change. This model cannot retract already approved/in-flight data. It also
cannot bound network tail traffic or supply crash recovery. In particular, granting in
memory and writing later is **not** a durable lease protocol. The durable store must persist
a grant/high-water mark before allowing consumption, reconcile known actuals and retain
unknown crash liability. Recovery must never replace unresolved grants with a fresh zero
ledger. No network byte/offset dedup, IPC authentication, database implementation or fake
traffic/persistence is provided by this module.

## Portable test vectors and verification

Canonical file: `shared/test-vectors/quota-v1.json`; SwiftPM copy:
`macos/Tests/FlowQuotaCoreTests/Fixtures/quota-v1.json`. Schema version 1 contains 22 decimal
conversions, 14 local-date cases, 18 evaluations, 12 notification cases and 3 budget
sequences (69 top-level cases, with additional steps inside each budget sequence).
Every byte value is a base-10 Int64 string so JSON consumers using IEEE-754 numbers do not
lose integers above 2^53; `null` denotes absence, never zero. Percentages and small rule
versions are JSON numbers. Time instants use UTC ISO 8601 and zones use IANA identifiers.
Expected errors match the public Swift error case names. Budget steps use named token aliases,
expected balances after each operation, and explicit increasing revisions for updates.
Windows must consume the same schema and compare the same outcomes when implemented.

After editing the canonical file:

```sh
python3 shared/test-vectors/sync-fixtures.py
python3 shared/test-vectors/sync-fixtures.py --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path macos --filter FlowQuotaCoreTests
```

The sync script owns only the fixture copy. `SharedVectorTests.testBundledVectorsMatchCanonicalBytes`
also compares bundled fixture bytes with the canonical file in the source checkout, so stale
copies fail tests. Core tests additionally cover 980 simultaneous reservation attempts,
98 concurrent connections repeatedly settling chunks, invalid reports, stale rule updates,
rule changes with pending liabilities, and cross-app/day/revision receipt rejection, including late and forged receipts while
new-version grants are pending. These are
arithmetic/concurrency tests, not real network throughput/latency or filter validation.

## Official basis

Read on 2026-11-04 against the toolchain/SDK above:

- [Swift language guide: Concurrency / Actors](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/):
  actor-isolated mutable state and uninterrupted synchronous methods with no suspension point.
- [Apple Foundation Calendar.dateComponents(_:from:)](https://developer.apple.com/documentation/foundation/calendar/datecomponents(_:from:)):
  extracts requested components using the calendar's time zone; available since macOS 10.10.
- [Apple Swift Int64.addingReportingOverflow(_:)](https://developer.apple.com/documentation/swift/int64/addingreportingoverflow(_:)):
  explicit overflow reporting; combined with `multipliedReportingOverflow` for checked conversion.
- Installed Foundation and Swift SDK declarations, plus compilation/tests, verify actual API use.

No external dependencies were added. Only arm64 macOS 27.2 is exercised here; macOS 14 runtime,
x86_64, restart/durable recovery, signed NetworkExtension operation, actual notification
delivery, and network blocking/tail traffic remain outside this domain verification.

## Verified test run (2026-11-04)

Final command, using full Xcode for XCTest without changing the system developer selection:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --package-path macos --scratch-path /tmp/flow-quota-domain-xcode-20261104 \
  --filter FlowQuotaCoreTests
python3 shared/test-vectors/sync-fixtures.py --check
```

Result: **29 Core XCTest methods passed, 0 failures**, at 22:12:19 Asia/Shanghai.
The fixture sync check passed. This filter does not run Store or Platform test methods.
The initial CommandLineTools selection compiled Core but lacked XCTest; selecting installed
full Xcode for the command resolved that toolchain issue. No approval/security settings changed.
All added handwritten Swift files are under 300 lines. Exact methods, grouped by source path:

`macos/Tests/FlowQuotaCoreTests/DecimalBytesTests.swift` (3):

- `DecimalBytesTests.testDecimalUnitsAreExact`
- `DecimalBytesTests.testInvalidGrammarAndSubByteValues`
- `DecimalBytesTests.testOverflowNeverWrapsOrRounds`

`macos/Tests/FlowQuotaCoreTests/LocalDayTests.swift` (4):

- `LocalDayTests.testLocalMidnightAndSleepAcrossMultipleDays`
- `LocalDayTests.testExplicitTimezoneAndClockMoveRecomputeKeys`
- `LocalDayTests.testGregorianLeapYearAndDSTDays`
- `LocalDayTests.testDateAndIdentityValidationAndDecodedIdentity`

`macos/Tests/FlowQuotaCoreTests/QuotaBudgetLedgerTests.swift` (11):

- `QuotaBudgetLedgerTests.testConcurrentReservationsCannotOverbookCap`
- `QuotaBudgetLedgerTests.testNinetyEightConcurrentConnectionsReconcileRepeatedChunks`
- `QuotaBudgetLedgerTests.testReconcileReleaseAndForfeit`
- `QuotaBudgetLedgerTests.testInvalidAndDuplicateReportsCannotChangeBalance`
- `QuotaBudgetLedgerTests.testRuleUpdatesKeepUsageAndPendingOldIdentity`
- `QuotaBudgetLedgerTests.testDisableAndReenableNeverResetCountersOrHolds`
- `QuotaBudgetLedgerTests.testStaleOrConflictingVersionFailsAndIdenticalUpdateIsIdempotent`
- `QuotaBudgetLedgerTests.testForeignDayAppAndRuleLedgerCannotSettleReceipts`
- `QuotaBudgetLedgerTests.testLateOldReceiptCannotReclaimNewRevisionReservations`
- `QuotaBudgetLedgerTests.testUnlimitedAndMaxCounterNeverOverflow`
- `QuotaBudgetLedgerTests.testBoundedPendingTokensAndInvalidRequests`

`macos/Tests/FlowQuotaCoreTests/QuotaEvaluationTests.swift` (5):

- `QuotaEvaluationTests.testThresholdAndCapBoundariesUseBothDirections`
- `QuotaEvaluationTests.testScopeUnlimitedAndUnavailableRemainDistinct`
- `QuotaEvaluationTests.testOverflowSaturatesAndThresholdDoesNotOverflow`
- `QuotaEvaluationTests.testWarningBlockDedupSurvivesReconnectAndCodableRoundTrip`
- `QuotaEvaluationTests.testRuleUpdatesAndIdentityBoundaries`

`macos/Tests/FlowQuotaCoreTests/SharedVectorTests.swift` (6):

- `SharedVectorTests.testBundledVectorsMatchCanonicalBytes`
- `SharedVectorTests.testSharedDecimalConversions`
- `SharedVectorTests.testSharedLocalDays`
- `SharedVectorTests.testSharedEvaluations`
- `SharedVectorTests.testSharedNotificationTransitions`
- `SharedVectorTests.testSharedBudgetSequences`


## 2026-11-05：后台大流量预警补充

在原应用每日规则之外，加入接口每日总量、接口短时、每个应用／系统服务短时三个独立检查。默认 1 GB／200 MB／200 MB，窗口最多 5 分钟，同来源短时冷却 10 分钟，可分别关闭；均为上传＋下载观测量。接口总量不参与原应用每日规则，应用合计也不参与接口预警。窗口可提前触发并记录实际观测时长，跨日／切网／间断不回填。当前日事件兼作通知队列，不扩展为历史报表；细节与边界见 `traffic-alerts.md`。
