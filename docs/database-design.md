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
Fresh databases run all migrations through the current version (v6). Upgrades from v1/v2 create an empty
interface table: application usage is never copied or summed into interface usage.
Each open acquires BEGIN IMMEDIATE before reading the version; all pending DDL, foreign-key checks,
and version updates commit together. A failing step rolls back all of them.
Unknown future versions fail without rewriting data. Never delete/recreate data as automatic upgrade recovery. The explicit, atomic
primary-key replacement for schema v5 is documented below. Tests seed a real version-1 database,
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
synchronous=FULL, secure_delete=ON, busy_timeout=1000 ms, wal_autocheckpoint=1000 pages. FULL is chosen
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

As of the 2026-11-06 user requirement, prunePreviousDays() atomically deletes
all non-current-local-day rows in traffic_alert_events, interface_usage_minutes,
application_usage_minutes (schema v7),
daily_interface_usage, budget_leases, notification_receipts and daily_usage.
This includes unsettled legacy leases and future-dated rows after clock rollback.
Rules, application identities, alert settings and UI preferences persist. This
explicitly replaces the earlier exception preserving old unresolved liabilities;
the current service is reminder-only. A future blocking engine must design and
validate its own liability retention before activation.

Every connection enables and verifies secure_delete=ON. After the purge transaction,
wal_checkpoint(TRUNCATE) removes old WAL frames; busy/errors propagate and are
retried rather than being marked complete. No migration or new business table is
needed. This is live-file cleanup, not a secure-erasure claim for filesystem/system
backups. Official SQLite PRAGMA documentation defines both settings.

The service purges before startup sampling and has a cancellable 30-second date
check independent of sampling/UI polling. Normal snapshot/sample calls also check
the date. Pausing collection therefore does not disable maintenance. On date change,
in-memory source attribution and short windows are reset. Failures are visible in
the snapshot coverage message and retried. A stopped/asleep computer cannot execute
cleanup: overdue deletion occurs when the service resumes or starts. Backward date
changes also purge everything outside the newly current day; no history is restored.
Development database copies and old installation artifacts are explicitly cleaned,
not included in the live database's daily pruning. Install rollback app copies are
deleted after a successful repair. No automatic traffic-data backup is created.

On uninstall, stop the service and close the store before deleting the database and
its -wal/-shm sidecars. Cleanup never removes user rules or settings.

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

## Schema v5: two network accounting categories (2026-11-05)

The service stores `metered` (automatic expensive / manual hotspot) and `ordinary`
(available ordinary Wi-Fi / wired) independently in the same SQLite file and
single QuotaStore actor. Unknown paths have no category and cannot add bytes.
No SSID, network contents, sample history, or new historical reporting is stored.

| Entity | v5 key / scope |
| --- | --- |
| applications | unchanged shared stable identity / display name |
| quota_rules | PRIMARY KEY(app_key, category); independent version / nullable limit per category |
| daily_usage | PRIMARY KEY(app_key, day, category); same integer byte bounds and FK |
| notification_receipts | PRIMARY KEY(app_key, day, kind, rule_version, category) |
| daily_interface_usage | PRIMARY KEY(day, category); independent of application attribution |
| traffic_alert_settings | one row per category; category TEXT PK instead of singleton id |
| traffic_alert_events | UUID PK retained; category NOT NULL added; cooldown lookup includes category |
| budget_leases | unchanged legacy future enforcement ledger; explicitly metered only |

`category TEXT NOT NULL DEFAULT 'metered' CHECK(category IN ('metered','ordinary'))`
applies to category fields. No application FK changes. Existing byte, day,
version, name, time, source and policy constraints remain. Existing lease APIs
operate only on metered usage/rules, so ordinary traffic cannot consume a legacy
lease budget. Ordinary observed increments still receive checked integer overflow
validation. Category participates in every relevant read, upsert, version check,
notification key, retry key, cooldown and pending-queue policy lookup.

Migration runs within the existing BEGIN IMMEDIATE transaction, before service
startup. Composite primary keys require explicit, data-preserving table replacement:
create new constrained child table, INSERT SELECT all legacy rows with metered
category, drop old child and rename replacement. These tables have no inbound
foreign keys; applications and budget_leases remain untouched, foreign_keys stays
ON. This planned versioned migration replaces the earlier blanket ban on table
replacement; automatic recovery by deleting data/recreating the database remains
forbidden. Any constraint/DDL/foreign_key_check failure rolls back all changes,
including user_version. No summing, identity rewriting or invented ordinary rows.
Events use ADD COLUMN with a metered default; replace the old cooldown index with
(day, category, kind, source_key, policy_version, occurred_at_ms). Other composite
primary keys serve category-scoped point reads/upserts; current-day bounded event
paging also uses the day/category index prefix. Query-plan tests check index use.

Copy the existing alert settings verbatim to metered, including disabled thresholds
and saved window/version. Initialize ordinary settings with all three thresholds
NULL, 180-second window, 600-second cooldown, version 1. No ordinary application
rules exist initially (reminders disabled). Metered fresh-install defaults remain
1 GB/day and 200 MB per 3-minute burst. User edits are never overwritten on reopen.

The 256-event cap remains shared across both categories for the current day.
Retention deletes previous-day usage, interface totals, receipts and events for
both categories; only metered usage with unresolved legacy leases is retained.
No transaction contains an await. Both category summaries are queried on the
existing 1–5 second UI cadence, interface/app writes remain approximately 2 seconds.
Path/category changes reset baselines and rolling windows; committed bytes stay
in their original category. Queued earned events retain their category and can
be delivered after a path change, subject to that category's current policy.

Official reference: SQLite ALTER TABLE, section “Making Other Kinds Of Table
Schema Changes”, https://www.sqlite.org/lang_altertable.html. The child tables
here have no inbound foreign keys, so foreign_keys need not be disabled; migration
and FK validation remain atomic. Validation uses temporary v4 databases, injected
migration failures, simulated counts, restart/day/category isolation tests, and
compilation; no generated network traffic.


## Schema v6 — current-day interface minute summaries (2026-11-05)

User-requested time charts introduce `interface_usage_minutes`, a durable minute
summary entity, separate from daily totals and application attribution. Design is
recorded before implementation. The UI reads it through category snapshots only.

| Field | Type / constraint / meaning |
| --- | --- |
| day | TEXT NOT NULL, existing Gregorian StoreDay CHECK; local day at observation |
| category | TEXT NOT NULL CHECK IN ('metered', 'ordinary') |
| minute_start_ms | INTEGER NOT NULL > 0, divisible by 60000; absolute UTC epoch millisecond minute |
| uploaded_bytes, downloaded_bytes | INTEGER NOT NULL >= 0, sum <= Int64.max; observed bytes |
| sample_count | INTEGER NOT NULL > 0; number of valid continuous deltas, including measured zero |

Primary key `(day, category, minute_start_ms)` supports both category-day ordered
reads and day cleanup; no additional index or foreign key is needed. There is no
stored total or application identity. Normal local days contain 1440 rows per
category (1500 on a 25-hour DST day). Only the current local day is retained;
startup/rollover cleanup deletes previous-day minute rows in the existing cleanup
transaction. UTC minute keys keep repeated local hours distinct.

Only `.measured` interface deltas receive an observation timestamp. Baselines,
unknown paths, counter resets, restart, pause, path/day changes and gaps over eight
seconds add no minute row. A cross-minute delta belongs to its ending minute;
there is no interpolation or recovery of unknown traffic. Sample counts express
partial observation, never a guarantee of full-minute coverage. Missing rows mean
unknown/unobserved; measured zero has a row with positive sample_count.

`recordSample` commits the minute increment and independent daily interface total
in the same existing BEGIN IMMEDIATE transaction, with bound parameters and checked
Int64 addition. It validates the observation's local day against the batch day.
Any validation/overflow/SQL failure rolls back the whole batch. Writes remain on
the existing roughly two-second interface cadence, one extra minute UPSERT per
measured sample; no per-packet writes, new connection, or durability downgrade.
Category snapshots read this bounded current-day summary on the existing UI poll.

Migration 5 -> 6 only CREATEs the empty new table and advances user_version inside
the migration transaction. Existing counters, policies, receipts and category
keys are untouched. Older daily totals cannot reconstruct time distribution;
upgraded charts begin at the first valid new observation. Migration failure rolls
back DDL/version. Tests cover preservation, rollback, FK/integrity, restart,
category separation, invalid dates, zero-vs-unknown, overflow atomicity, cleanup
and the ordered query plan using the composite primary-key index.

Official basis: SQLite CREATE TABLE / CHECK / composite primary keys
(https://sqlite.org/lang_createtable.html), transactions
(https://sqlite.org/lang_transaction.html), and EXPLAIN QUERY PLAN
(https://sqlite.org/eqp.html); system SQLite, Swift tools 6.0 / macOS 14 minimum.

## Schema v7 — application minute attribution (2026-11-06)

User requirement: compare applications within a selected current-day interval,
with separate stacked upload/download bars and two directional application pies.
Daily application totals and interface minutes cannot reconstruct that history.
Add `application_usage_minutes`, one observed app/minute/category aggregate:
`day TEXT`, `category TEXT` (`metered`/`ordinary`), `minute_start_ms INTEGER`
(positive UTC epoch milliseconds divisible by 60000), `app_key TEXT` FK to
applications, uploaded/downloaded INTEGER bytes >=0 (combined <= Int64.max),
`sample_count INTEGER >0`. All columns NOT NULL; PK(day, category,
minute_start_ms, app_key) supports category/range reads and current-day cleanup.
No extra index: app filters use the same day/category/minute range and a residual
identity condition. Confirm with EXPLAIN QUERY PLAN and representative fixtures.

Only sources with a measured delta (including a measured zero) participate;
startup/restart, path/day changes, >8 s gaps, unknown preexisting processes and
counter rollback establish baselines, never fake zero observations. A process
proven born within a continuous interval keeps existing first-burst semantics.
Minute attribution uses the sample end, without interpolation, and commits in
`recordSample`'s existing transaction with daily app totals. Per-app minute
updates use checked integer addition; failure rolls back the entire batch.
Writes retain the existing nettop cadence; no per-packet writes or second writer.

The service exposes a bounded on-demand interval query instead of attaching all
app minutes to every snapshot. Only current local day, minute-aligned range
within that day (up to 25 h for DST), and optional canonical app identity are
accepted. SQL groups by 5 min (<=1 h) or 30 min. Preserve every process,
including shared proxy kernels; do not fold low-ranked processes into a hidden
remainder. Clash source evidence is separately namespaced and never summed with
processes. Replies permit up to 50 buckets × 257 rows, with the unchanged 1 MiB
IPC limit; size/capacity errors remain visible. The main chart independently
reads interface minutes from the service snapshot, so a failed process query
cannot remove the total. Missing minutes remain unknown, measured zero requires
positive sample_count. Pies describe process observations, not a partition of
physical bytes. See `traffic-accounting.md` for per-direction discrepancies.

Migration 6→7 creates only this empty table transactionally and preserves existing
rows/settings, without backfilling prior daily totals. Normal current-day pruning
must include the new table, including future/old labels after clock changes.
No historical retention, network content or sampling log is introduced. Existing
secure_delete/WAL cleanup policy applies. UI switches/range requests cancel stale
fetches and keep same-query chart content during polling; results from another
category/range/day never appear under the current selection.

2026-11-06 clarification: the primary paired columns show physical interface
upload/download, preserving every observed byte when application identification
fails. Process observations and auxiliary Clash sources remain fully inspectable
in separate sections. No table or migration is needed for this presentation
correction; no source, gap or proxy byte is written into another ledger.


## Schema v8：预警触发时的应用归因（2026-11-06）

业务实体仍是 `traffic_alert_events`，新增可空 `applications_json TEXT`，不新建表或索引。
该列是事件证据的一部分，与事件在同一事务写入，发生后不随应用账本、名称或配置更新。
JSON 编码版本由本次结构固定，包含 `items`（最多 128 项：canonical app key、触发时名称、上传及下载 integer bytes）、
`observedAt`（最近应用观测的绝对时间，可空）、`omittedCount` 及有界 `notice`。
所有计数非负，单项收发合计不超过 Int64.max；名称最多 256 UTF-8 bytes、key 最多 2048 bytes，JSON 最多 524288 bytes；
读取时重新校验身份、唯一性、数值范围及排序，坏数据明确报错。JSON 作为一个不可变值整体读写，不使用 SQL JSON 函数。
SQL CHECK 约束 TEXT/NULL 和编码字节上限；细项约束由同一个 Swift 模型在写入和读取处验证。

- 每日接口预警：服务在阈值触发时读取同类别已提交的当天应用用量，并立即冻结；只表示最近已持久化的归因，应用与接口采样异步。
- 接口短时预警：独立有界内存窗口保持应用方向增量，即使应用预警开关关闭也可归因；仅取落在接口事件连续观测窗口内的完整 delta 桶，不插值。
  保留最多 450 桶／128 来源，使用单调时钟；切网、跨日、配置变化、暂停、重启及超过 8 秒的间断重建。
  缺失或超限仅使明细不可用，不能阻止接口事件产生。接口时段与应用时段尾端可能不同，显示最近应用观测时间和边界说明。
- 应用预警：冻结触发应用同一滚动窗口的上传／下载，不混入其他应用。
- 超过 128 个正用量应用的日快照按合计降序保留前 128 项并记录省略数量；短时窗口超限显示不可用，不伪造其他应用合计。
- 普通轮询／历史分页只返回前三项名称组成的最多 256 UTF-8 bytes 摘要；展开后按当前日、类别和事件 UUID 查询一个完整快照。
  完整明细不随全部事件重复传输，不提高 1 MiB IPC 限制。通知只依赖原事件字段。

v7→v8 使用 `ALTER TABLE ... ADD COLUMN ... DEFAULT NULL`，在既有迁移事务内执行；旧事件保留 NULL，界面显示“未记录应用明细”。
不回填、不改旧计数、不重建数据库。精确 UUID 重试比较完整快照；ACK 只写 scheduled_at_ms。
清理仍删除非当前日事件，JSON 随父行一起删除，沿用 secure_delete 及 WAL 截断，不做备份。
按主键读取单条完整证据，常规摘要查询及冷却索引不变，无新增索引需求。

依据：SQLite 官方 ALTER TABLE / ADD COLUMN 文档（https://www.sqlite.org/lang_altertable.html），新增可空列无需重写旧记录；
SwiftUI `View.task(id:priority:_:)` 官方文档，用事件 UUID 与类别驱动按需读取并取消已离开视图的任务。
适用工具链：Swift 6、macOS 14+；迁移、重试一致性、跨日清理、窗口边界及实际编译结果见本次测试。
