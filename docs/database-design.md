# Flow Quota SQLite ledger

Status: implementation contract, 2026-11-05. Scope: macOS protection service only;
Core models remain the wire/domain contract. No packet, URL, host, payload, or
historical reporting log is stored. The UI never opens this database.

## Environment and official basis

The package uses Swift tools 6.0, macOS 14 minimum, and the system SQLite C API
through the existing CSQLite shim. Development verification uses Swift 6.4.2,
macOS SDK 27.2, arm64; record the linked SQLite version in tests. SQL deliberately
uses ordinary tables with explicit `typeof` checks rather than requiring STRICT
or date normalization behavior that varies across system SQLite releases.

Official references (consulted 2026-11-04):
- https://sqlite.org/pragma.html — foreign_keys, synchronous, user_version, checkpoint.
- https://sqlite.org/wal.html — WAL durability and local filesystem restrictions.
- https://sqlite.org/lang_transaction.html — BEGIN IMMEDIATE and rollback.
- https://sqlite.org/c3ref/bind_blob.html — bound values and SQLITE_TRANSIENT.
- https://sqlite.org/foreignkeys.html — connection-level FK enabling and verification.
- https://sqlite.org/eqp.html — query plans are diagnostics, not a stable API.

## Entities, constraints, and migrations

`PRAGMA user_version` is the sole schema version; no redundant migration table.
Version 1 is the initial ledger (first four tables below); version 2 adds leases
and their liability index; version 3 adds the independent daily interface meter.
Fresh databases run all three migrations. Upgrades from v1/v2 create an empty
interface table: application usage is never copied or summed into interface usage.
Each open acquires BEGIN IMMEDIATE before reading the version; all pending DDL, foreign-key checks,
and version updates commit together. A failing step rolls back all of them.
Unknown future versions fail without rewriting data. Never drop/rebuild a table
or delete the file as an upgrade strategy. Tests seed a real version-1 database,
including a deliberately conflicting version-2 index to exercise DDL rollback
after the new lease table has already been created.

| Table | Persistent entity and keys | Fields / constraints |
| --- | --- | --- |
| applications | Stable verified platform identity; app_key TEXT PK NOT NULL | Nonempty key and name TEXT NOT NULL. No PID identity. Name updates do not reset counters or rules. |
| quota_rules | One current rule per app; app_key PK/FK applications | limit_bytes INTEGER nullable (NULL = unlimited, otherwise >0); warning_percent INTEGER 1…99; version INTEGER >0. Same version + same content is an idempotent retry; older version or conflicting equal version fails. |
| daily_usage | Current natural-day summary; PK(app_key, day), FK applications | uploaded_bytes/downloaded_bytes INTEGER >=0, total <= Int64.max. No floats; all counters are bytes. |
| notification_receipts | Deduplication claim; PK(app_key, day, kind, rule_version), FK applications | kind is warning or exceeded; rule_version INTEGER >0. Claim requires the current rule version. Old receipts survive rule edits until day cleanup. |
| daily_interface_usage | Independent observed interface meter; day TEXT PK NOT NULL, no application FK | uploaded_bytes/downloaded_bytes INTEGER >=0, sum <= Int64.max; the same StoreDay Gregorian CHECK as daily_usage. No stored total or timestamps. |
| budget_leases | Durable grant/final settlement; lease_id TEXT PK, FK applications | app_key, day, rule_version >0, reserved_bytes >0, expires_at_ms INTEGER >0; settled upload/download both NULL (outstanding) or both nonnegative integers with sum <= reserved_bytes. No stored derived total/state. |

All required fields are NOT NULL. Integer fields explicitly check `typeof =
'integer'`, ranges and addition bounds, preventing SQLite promotion to REAL.
Text identity/lease identifiers reject embedded NUL at the API boundary. Day is
ASCII Gregorian YYYY-MM-DD, year 0001…9999, validated including month lengths and
leap years in SQL CHECK and Core LocalDay.isValidKey (reused by the store). Day labels use the service's local timezone
at attribution time; timezone is not a separate quota namespace. Timestamps use
integer UTC Unix milliseconds. MB/GB conversion belongs to Core, never SQL.

FKs use RESTRICT semantics: an app cannot disappear while referenced. Receipts
and leases refer to applications, not the mutable current rule version, so rule
changes cannot orphan prior evidence. Versions are validated transactionally.
The database is scoped to the local macOS service installation; a future Windows
implementation must add user SID isolation explicitly.

## Writes, budgets, and recovery

One QuotaStore actor owns one connection, with synchronous private helpers and no
await inside a transaction. BEGIN IMMEDIATE covers rule version checks, usage
read/modify/write, notification claims, reservation checks, and settlement. This
also serializes accidental competing connections; production should instantiate
one owner. Every runtime value uses prepared/bound SQL; only static DDL/PRAGMAs
are literal SQL. All statements finalize; close() is explicit and idempotent,
with deinit as a fallback. Errors propagate with SQLite extended result codes;
rollback failures are reported with the original error.

Connection setup enables and reads back foreign_keys=ON, journal_mode=WAL,
synchronous=FULL, busy_timeout=1000 ms, wal_autocheckpoint=1000 pages. FULL is chosen
because granting a lease before durable commit would reissue consumed bytes on
power failure. WAL permits readers without blocking the writer; no separate read
pool is needed. Default automatic PASSIVE checkpoints run at the configured page
threshold; close uses SQLite's normal close behavior. WAL may exceed the threshold
while readers hold old snapshots; the service must not hold long read transactions
and should monitor disk capacity. FULL cannot fix dishonest storage hardware or
unsupported network filesystem locking. Use a private local service-owned path.

For a day, charged budget = actual uploaded + downloaded + SUM(outstanding
reserved_bytes), computed with checked Int64 arithmetic (SQLite integer SUM
also throws on overflow instead of promoting to REAL). reserveBudget requires a
registered app, current rule version, today's local day, a future expiry no later
than the next local midnight, and enough remaining limit (NULL still enforces the
integer bound). The complete requested amount is granted or quotaExceeded is
thrown. It returns only after durable commit. Duplicate matching live requests
return the original grant; conflicting IDs fail; settled, expired, old-day, or
stale-version grants cannot be replayed as new authority.

settleBudget accepts authoritative FINAL cumulative up/down counters for one
lease, not deltas. It atomically adds actual usage and removes the full outstanding
liability. Repeating the exact settlement returns the receipt without counting
again; conflicting totals, over-consumption, unknown IDs, and first settlement
after expiry/day change fail. Expiry alone NEVER releases liability: an unknown
consumer may have spent the grant just before disconnecting. Reopening preserves
all outstanding liabilities. Late/unknown grants remain charged conservatively
until day cleanup; the store does not invent uploaded/downloaded counts for them.
An exact already-settled retry may be read after expiry, until day cleanup.

recordUsage accepts additive nonnegative Int64 deltas for already-attributed
traffic outside the lease path (including unlimited monitoring). Do NOT report
lease traffic through both APIs. It can record genuine over-limit use and never
clamps counters to a rule limit; later grants then fail. It ensures actual plus
outstanding liability still fits Int64. Any validation/write failure rolls back.

The production store recomputes a Gregorian calendar using TimeZone.current on
every admission, settlement, and cleanup operation. Only tests can inject a fixed
calendar and clock. Day labels delegate to Core LocalDay.key.

The protection service must stop spending a grant when its rule version, local
day, network scope, or expiry changes, and authenticate final counters over IPC.
SQLite cannot revoke in-flight network bytes or authenticate a caller. Store
balances are authoritative for admission, not proof of NetworkExtension readiness.
Snapshot contains actual settled usage per Core's model; the service must also
read budgetBalance for conservative outstanding liability, and must not present
unknown outstanding consumption as measured zero.

## Retention, reads, and performance

prunePreviousDays() atomically removes prior-day notification receipts and settled
leases. It removes prior-day usage only where no outstanding lease exists for the
same app/day. ALL outstanding leases remain, including expired/prior-day leases;
cleanup never assumes an old consumer stopped or reclaims an uncertain grant.
The associated actual counters remain too, preserving the entire conservative
balance across reopen. This safety evidence is an exception to normal current-day
retention, not a historical reporting feature; without authenticated reconciliation,
it can accumulate. Applications/rules, today's rows, and future-dated evidence remain.

The service calls cleanup on startup/day change after invalidating prior-day grants;
there is no automatic clock-independent expiry reset. Keeping present/future rows
prevents erasing a revisited retained day. If the clock moves backward beyond
already-pruned resolved days, the service must treat its clock as untrusted and
suspend admission; the store cannot reconstruct deleted summaries. V1 is not an
anti-tampering system and does not persist a separate trusted-clock watermark.
On uninstall, stop protection and close the store before the user's data deletion
choice, including SQLite -wal/-shm sidecars. No deletion API silently removes rules.

The usage PK supports app+day lookups. Notification and lease PKs support exact
retry/dedup lookups. A partial lease index `(app_key, day) WHERE uploaded_bytes IS
NULL` supports outstanding liability without scanning settled receipts. Snapshot
scans applications deliberately (all identities must be displayed), joining rules
by app PK and usage by app+day PK; the caller sorts presentation in Core/UI.
Cleanup scans daily rows: the product retains one day, so extra day indexes are
not justified. Tests use EXPLAIN QUERY PLAN with representative identities and
check indexed searches, without depending on the full unstable diagnostic text.

No per-packet writes. The service chooses bounded byte grants and batches counters;
crash uncertainty is at most the sum of durable outstanding grants per app/day,
already withheld from new budget. This change does not claim measured throughput,
CPU, memory, tail traffic, or power-failure survival on physical hardware.

## Validation record

`PATH=/usr/bin:/bin:/usr/sbin:/sbin scripts/test-macos.sh --filter FlowQuotaStoreTests`
passes 17 tests (the original 15 plus two canonical-identity regression cases)
on arm64, Swift 6.4.2, SDK 27.2, linked SQLite 3.54.0 (2026-11-04). The script uses
Xcode's DEVELOPER_DIR and workspace .artifacts caches. The PATH prefix selects
/usr/bin/python3 for the fixture precheck because the environment's Miniconda
python3 fails with Bad CPU type; no shared script was changed. All hand-written files remain
below 300 lines.

Verified: disk reopen preserves identities/rules/counters/claims/lease liabilities;
version increases and exact retries; old/equal-conflicting rule rejection; unknown
FKs and malformed dates/bytes; native SQLite CHECK/PK constraints; SQL preparation/binding failure cleanup; Int64 overflow;
80 concurrent grants across two independent connections respect actual+pending
cap; 20 concurrent identical settlements count once; expired/old-day/stale grants
cannot reissue budget; lower quota includes existing liabilities; injected failure
after the usage write rolls settlement back; real frozen v1 fixture migration;
failed v2 index creation rolls back new table and version; future schemas and
orphaned v1 data fail without rebuild; current-day cleanup preserves unresolved
prior-day liability; EXPLAIN confirms composite-key and partial-index searches
with 200 representative applications.

Not verified: physical power interruption/fsync hardware guarantees, disk-full or
filesystem corruption recovery, deployment on macOS 14/Intel, live system timezone
mutation, sustained throughput/CPU/memory/write amplification, or real network
protection. The parent service/extension must authenticate IPC, stop revoked grants,
choose bounded batch sizes, surface unknown liabilities and handle clock anomalies.
No claim of signed/entitled NetworkExtension readiness is made by this module.

## Public integration API

All actor methods are synchronous/throwing internally and `try await` from callers.

```swift
public actor QuotaStore {
    public init(path: String) throws
    public func close() throws
    public func registerApplication(_ identity: AppIdentity) throws
    public func saveRule(appKey: String, rule: QuotaRule) throws
    public func loadRules() throws -> [String: QuotaRule]
    public func snapshot(day: String) throws -> [ApplicationSnapshot]
    public func recordUsage(appKey: String, day: String,
                            uploadedBytes: Int64, downloadedBytes: Int64) throws
    public func claimNotification(appKey: String, day: String,
                                  kind: NotificationKind, ruleVersion: Int64) throws -> Bool
    public func budgetBalance(appKey: String, day: String) throws -> BudgetBalance
    public func reserveBudget(id: String, appKey: String, day: String, bytes: Int64,
                              ruleVersion: Int64, expiresAt: Date) throws -> BudgetLease
    public func settleBudget(id: String, uploadedBytes: Int64,
                             downloadedBytes: Int64) throws -> BudgetLease
    public func recordSample(day: String, increments: [UsageIncrement],
                             interfaceIncrement: InterfaceUsage? = nil) throws
    public func interfaceUsage(day: String) throws -> InterfaceUsage?
    public func prunePreviousDays() throws
}
```

StoreTypes.swift exports StoreError, NotificationKind (Core `QuotaNotificationKind` alias: `warning`, `blocked`),
BudgetBalance (`usedBytes`, `outstandingBytes`, `chargedBytes`) and BudgetLease
(`id`, `appKey`, `day`, `ruleVersion`, `reservedBytes`, `expiresAt`, nullable final
`uploadedBytes`/`downloadedBytes`, computed `isSettled`). Lease and balance values
are immutable, Sendable and Equatable, and can only be returned by the store.


## 身份一致性复查修正

所有账本边界要求 app_key 为 Unicode NFC、非空且不含 NUL。Swift 的规范等价相等与 SQLite BINARY 字节相等不能混用。旧库打开时校验已有身份；非规范身份或冲突须明确报错并单独修复，不静默合并或丢弃用量。loadRules 防御性检测重复键而不触发 Dictionary 唯一键陷阱。

通知类型复用 Core 的 QuotaNotificationKind，blocked 在 SQL 中映射到既有 exceeded 存储值，不改动原有表约束。


## Reminder-only sampling integration (2026-11-04)

User narrowed this iteration to observed traffic and threshold notifications; no filtering. Application attribution reuses applications, quota_rules, daily_usage and notification_receipts. The independently approved interface meter uses schema v3 as described below. Register a bounded batch of canonical application identities and additive byte deltas in one transaction per sample. A failed entry rolls back the entire batch; callers do not retry ambiguously committed samples. Runtime counter baselines are ephemeral: startup, path/day changes, gaps and counter resets rebaseline instead of backfilling unknown history.

Notification proposals are derived from persisted current-day counters and rules, excluding durable receipts. The main app submits a deterministic notification identifier to UserNotifications, then acknowledges successful OS scheduling to the Agent; only then is the existing receipt recorded. Legacy blocked/exceeded values mean threshold reached in this iteration, never connection blocking. An OS scheduling ACK does not prove user-visible delivery; crash between scheduling and receipt can cause a retry, using the same OS identifier. No exactly-once presentation guarantee is claimed. Notifications require the menu bar app to remain running; Agent sampling remains independent of panel visibility.

Application identity uses canonical executable/application paths, not PID or truncated nettop names. Process birth time distinguishes PID reuse within the sampler and permits a first cumulative count only when the process is proven born inside a continuous observed interval. Resolving to an enclosing outer application groups known helpers, without treating unverified attribution as accurate. Path changes can create a new identity. Per-application totals may overlap under proxies; do not present their sum as physical hotspot usage.


## Independent daily interface meter (2026-11-05)

The interface meter and application attribution are distinct observed entities.
Proxy forwarding can overlap app counters; unresolved app identity can omit them.
Consequently, `daily_interface_usage` is a necessary separate meter, not a cache
or a derived application sum. One row represents the sum of observed interface
deltas for one local day across eligible expensive/manually marked paths. Path
changes do not create a new daily budget or erase the persisted row. The caller
rebuilds its baseline on restart/day/path changes and gaps; unknown intervals are
never reconstructed. This is observed service runtime usage, not a carrier bill.

The Core `InterfaceUsage` value has day/uploadedBytes/downloadedBytes; its optional
`totalBytes` rejects negative or overflowing values. Store validates Gregorian
day, equality with the batch day, nonnegative integer bytes and both per-direction
and combined cumulative Int64 bounds. `recordSample(day:increments:interfaceIncrement:)`
accepts an optional interface delta defaulting to nil. Nil leaves the interface
meter untouched. A zero delta creates a known zero row; an absent row is returned
as nil by `interfaceUsage(day:)`, preserving unknown versus observed zero. The
interface query never consults applications or their usage. An interface-only
sample needs no application identity or rule.

The interface task can submit empty application batches at its own two-second
cadence, independently of nettop; the store imposes no shared sampling clock.
The existing actor/BEGIN IMMEDIATE transaction covers identity registration,
application deltas and interface read/modify/upsert. Any invalid delta, overflow
or SQLite failure rolls back the entire batch, including names and newly created
identities. Additive samples must not be retried after an ambiguous commit. The
existing WAL/FULL/busy timeout policy and sampling cadence remain applicable.
There is no interface notification receipt or inferred interface quota.

`day` is the sole primary key and supports the exact-day SELECT and prior-day
DELETE; no redundant index is added. `prunePreviousDays()` deletes all earlier
interface rows in its existing cleanup transaction, independently of legacy app
leases; it preserves today's row, rules and identities. No interface history,
interface names, SSIDs, IPs, counter baselines or last-sampled timestamps persist.
Reopening restores the observed daily total, but not baseline or freshness.

Migration v3 uses only CREATE TABLE and user_version update inside the existing
migration transaction, with no backfill. Any DDL, identity or FK validation failure
rolls schema/version changes back. Tests retain an independent frozen v1 fixture
and add an independent v2 lease fixture. Coverage includes v1/v2 preservation,
failed-v3 retry, future-schema rejection, SQL date/type/range/PK checks, additive
restart recovery, unknown/zero, pruning, atomic rollback and primary-key query
plans. These are fixture/unit checks only: no hotspot or real-network validation
is authorized. Verification handoff on 2026-11-05: FlowQuotaStore compiled with
Swift 6.4.2 in an isolated /private/tmp scratch directory. Main integration
completed the full 164-test suite (Core 29, Store 39, Platform 48, App 37,
Agent 11), including the integrated pipeline driven by a fake interface reader.
The interface task independently invokes day pruning even when app sampling is absent. The initial migration checks used only temporary databases. Subsequent paused
installation verification upgraded the real v2 database to v3 after a private backup;
19 app rows and 19 current-day usage rows, along with rules and receipts, retained
identical checksums. quick_check passed, foreign_key_check returned no violations,
and daily_interface_usage remained empty (no fabricated historical total). No real
network sampling, hotspot experiments or traffic generation were performed.

SQLite official basis for v3:
- https://sqlite.org/lang_createtable.html — PRIMARY KEY, NOT NULL and CHECK.
- https://sqlite.org/lang_transaction.html — transactional DDL/write rollback.
- https://sqlite.org/datatype3.html — INTEGER affinity requires explicit typeof checks.

## Background traffic alerts: schema v4 design (2026-11-05)

Approved scope: daily interface-total alerts, rolling-window interface/app alerts,
precise system-component presentation, and current-day alert events. No traffic
content, addresses, per-tick persisted history or inferred interface-minus-app bytes.

Two persistent entities are necessary: `traffic_alert_settings` is one versioned
configuration (singleton id=1; nullable positive Int64 byte thresholds for daily
interface, interface burst and each app burst; window 60…900 seconds; cooldown
60…86400 seconds; version>0). Initial defaults: 1 GB daily, 200 MB in at most 5
minutes for interface and each app, 10-minute cooldown. All units decimal bytes.
Disabling a threshold stores NULL; rules remain independent of legacy app quotas.

`traffic_alert_events` is durable evidence and the notification outbox in one row:
UUID id PK, validated local day, kind, actual source key (empty for interface;
canonical app key for attribution), source display name snapshot, integer observed
and threshold bytes, configured window and actual observed seconds, policy version,
UTC occurred_at_ms and nullable scheduled_at_ms. It deliberately has no application
FK: interface alerts have no app owner and records must remain interpretable if a
process disappears. Settings versions are retained in events rather than FK'd to
mutable singleton settings. Constraints check types, ranges, nonempty names and
kind/source relationships. No duplicate receipt table; scheduling ACK updates the
same event only after OS acceptance, not proof of a visible banner.

Transactions validate settings revision and enforce daily-once (per version) or
cooldown (kind/source/version), then insert. A shared composite index on day,
kind, source_key, policy_version, occurred_at_ms supports dedup/cooldown queries.
The day prefix also supports pruning and a bounded current-day list; no extra
history index. Bound to 256 events/day and 128 app sources/window. At the limit,
report coverage/cap status; never claim all apps were checked. Windows are memory
only, bounded to 450 two-second buckets and use monotonic time. Gaps >8 seconds,
path/day/version changes, pause/restart reset windows; partial boundary buckets
are excluded conservatively, no prorated fabricated bytes. Thresholds can fire
before a full window; events include actual observed interval.

v4 adds both tables/index plus default settings in the same migration transaction,
retaining v1–v3 ledgers. Settings are user configuration and persist across days;
events older than the current local day are deleted by existing day pruning.
Migration failure rolls back DDL and user_version. Unit tests cover frozen v3
upgrade, constraints, version conflicts, cooldown/restart/clock rollback, caps,
ACK/retry, retention and EXPLAIN. Installed data will only be migrated with a
backup and paused startup; no hotspot experiment is authorized.


v4 storage contract (implemented):
- `traffic_alert_settings`: `id INTEGER PRIMARY KEY CHECK(id=1)`, nullable positive
  INTEGER `daily_interface_bytes`, `interface_burst_bytes`, `application_burst_bytes`,
  INTEGER `window_seconds` (60…900), `cooldown_seconds` (60…86400), `version` (>0).
  Every numeric field checks `typeof`; singleton defaults are inserted by migration.
- `traffic_alert_events`: TEXT `id` UUID PK (canonical uppercase on API writes),
  `day`, `kind` (`dailyInterface`, `interfaceBurst`, `applicationBurst`), `source_key`,
  `source_name`; INTEGER `observed_bytes` >= `threshold_bytes` >0,
  `window_seconds`, `observed_seconds`, `policy_version` >0, `occurred_at_ms`,
  nullable INTEGER `scheduled_at_ms`. Daily events require both seconds fields 0;
  bursts require window 60…900 and observed 1…window. Timestamps are UTC epoch
  milliseconds, rounded to nearest millisecond, in 1…253402300799999; scheduled
  time must be >= occurrence. UUID shape/hex, Gregorian day, text types/NUL,
  UTF-8 byte limits (key <=2048; name 1…256), nonblank names/app keys, and
  kind/source relationships are SQL constraints. NFC application keys are checked
  byte-for-byte at the API boundary (SQLite has no built-in NFC normalization).
- The sole explicit index is `traffic_alert_lookup(day, kind, source_key,
  policy_version, occurred_at_ms)`; implicit primary-key indexes remain. Queries
  bind values. Day lists use `ORDER BY occurred_at_ms DESC, id DESC LIMIT ? OFFSET ?` (defaults 256/0; limit 1…256, offset 0…256);
  the day index bounds filtering and SQLite sorts the bounded daily evidence.
- `BEGIN IMMEDIATE` serializes policy read/check/write, event admission and ACK
  across connections. Exact policy retries succeed; any other write must have a
  strictly greater revision (comparison only, no overflow-prone version increment).
  Off/stale version/threshold/window returns false for event admission. New events
  must have nil scheduledAt, the current clock/calendar day and an occurrence on
  that same day; historical day labels cannot be forged to bypass retention.
- UUID retries compare all immutable payload fields at stored millisecond precision
  and return false (no new row), including after ACK (original nil scheduling
  timestamp or the identical stored ACK timestamp). Conflicting UUID payloads
  throw; an ACK cannot be imported through record. Daily dedup uses kind/day/source/
  version. Bursts query MAX(occurred_at_ms) for the same identity independently of
  a cooldown lower bound; backward or equal occurrence is suppressed, even after
  restart. Cooldown uses current policy seconds and subtraction within checked
  timestamp ranges. Capacity is checked after dedup: 256 accepted rows/day, then
  TrafficAlertError.eventLimit. No fake applications or interface foreign keys.
- ACK requires current clock day, existing UUID/day and current enabled policy
  version/threshold/window; it writes clock milliseconds only for a pending row.
  Exact ACK retries preserve the original timestamp; a clock before occurrence
  fails validation. Prior-day pruning deletes events in the existing transaction
  and keeps settings. No schema triggers, additional tables or indexes are added.
- Migration 3→4 creates two tables, one index and initial settings in the existing
  migration transaction. Legacy app/rule/usage/receipt/lease/interface rows are
  untouched; DDL/default/index failure rolls back schema and user_version.

Official basis: SQLite CREATE TABLE CHECK/type rules, transactions, aggregate MAX,
and EXPLAIN QUERY PLAN (`https://sqlite.org/lang_createtable.html`,
`https://sqlite.org/lang_transaction.html`, `https://sqlite.org/lang_aggfunc.html`,
`https://sqlite.org/eqp.html`). Target: Swift tools 6.0, macOS 14 minimum; local
verification toolchain Swift 6.4.2 / SDK 27.2. Existing WAL/FULL/busy-timeout
connection policy is retained. Validation results follow.


v4 verification (2026-11-05): an isolated temporary Swift package containing only
Core, Store, CSQLite and Store tests compiled using Xcode 27.2 / Swift 6.4.2 and
macOS SDK 27.2. All 60 Store tests in 13 suites passed. Final review then extended
UUID retry handling to accept an identical already-ACKed row, while rejecting a
different supplied ACK timestamp and preserving nil-only admission of new rows;
all 21 traffic-alert tests in 5 suites passed again after that change. Production
Store files are all below 300 lines (largest existing file: 193 lines).

Coverage includes frozen independent v3 schema/data upgrade with every legacy
field and DDL compared before/after; conflicting-index and post-DDL-validation
migration rollback; direct SQL type/range/enum/day/source/UUID constraints; decoded
input validation; exact UTF-8 boundaries; revision and daily admission races over
two connections; disabled/stale policies; restart/cooldown/clock-back suppression;
UUID retry/ACK persistence and conflicts; 256-row cap and stable 32-row pagination;
transaction rollback for insert/policy/ACK/prune failures; settings retention; and
EXPLAIN QUERY PLAN using the composite index on 256 representative events. Day
listing uses that index for filtering and a temporary sort for the specified order;
no additional ordering index was introduced. integrity_check and foreign_key_check
passed for the temporary fixtures. The initial CommandLineTools-only test attempts
failed to discover Testing/TestingMacros; selecting the project's Xcode toolchain
resolved this environment issue without changing repository build scripts.

No shared build/test script, installed database migration, real network sampling,
hotspot experiment or generated upload/download was used for this Store delivery.
Installed-database migration and OS notification scheduling remain main-task
integration/installation verification, not claims of these isolated Store tests.


2026-11-05 default-window update: newly created alert settings (including first
v3→v4 upgrade) use a 180-second window instead of 300 seconds. Existing v4
settings are read unchanged, including explicitly saved five-minute windows;
no new schema version, table, or automatic UPDATE is needed. The 60–900-second
constraint, cooldown, thresholds, and persistence/version semantics are unchanged.


### v4 短时事件写入失败恢复（2026-11-05，无 schema 变更）

已达到阈值但尚未入库的事件在 Agent 内存中有界重试：每个类别／应用身份保留最早一条，两个接口类别加至多 128 个应用来源，共最多 130 项，固定 UUID、原用量和发生时间。后续提交仍经过既有 `recordTrafficAlert` 事务与日期、版本、冷却和每日容量检查；提交返回已抑制也可移除候选，异常则保留。旧异步写入按 UUID 移除，不能删除较新版本的同来源候选。当前日／配置变化清理不合格候选；服务退出无法保留未入库候选，这是持久化前的故障边界。

无需新实体、采样流水或重试表；`traffic_alert_events` 仍是唯一持久化事件／通知待发队列。每日事件失败与短时检查分开，应用事件失败按来源隔离，不为了通过事务而改变现有约束。重试并不重新写入流量用量，也不延长滚动窗口或把间断期间算作连续观测。
