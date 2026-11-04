# Flow Quota SQLite ledger

Status: implementation contract, 2026-11-04. Scope: macOS protection service only;
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
and their liability index. Fresh databases run both migrations. Each open acquires
BEGIN IMMEDIATE before reading the version; all pending DDL, foreign-key checks,
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
