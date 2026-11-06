import FlowQuotaCore
import Testing
@testable import FlowQuotaStore

struct NotificationReceiptTests {
    @Test func receiptKindsDaysAndRuleVersionsSurviveReopen() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        try await fixture.seed(store, key: "other")
        #expect(try await store.deliveredNotifications(day: fixture.day).isEmpty)
        for kind in [NotificationKind.warning, .blocked] {
            #expect(try await store.claimNotification(appKey: "signed:app", day: fixture.day,
                                                     kind: kind, ruleVersion: 1))
        }
        try await store.saveRule(appKey: "signed:app", rule: QuotaRule(limitBytes: 200, version: 2))
        #expect(try await store.claimNotification(appKey: "signed:app", day: fixture.day,
                                                 kind: .warning, ruleVersion: 2))
        #expect(try await store.claimNotification(appKey: "other", day: fixture.day,
                                                 kind: .blocked, ruleVersion: 1))
        let previousDay = "2026-11-03"
        let futureDay = "2026-11-05"
        for day in [previousDay, futureDay] {
            #expect(try await store.claimNotification(appKey: "signed:app", day: day,
                                                     kind: .blocked, ruleVersion: 2))
        }
        let first = try QuotaIdentity(appKey: "signed:app", day: fixture.day, ruleVersion: 1)
        let second = try QuotaIdentity(appKey: "signed:app", day: fixture.day, ruleVersion: 2)
        let other = try QuotaIdentity(appKey: "other", day: fixture.day, ruleVersion: 1)
        let expected: Set<QuotaNotificationKey> = [
            QuotaNotificationKey(identity: first, kind: .warning),
            QuotaNotificationKey(identity: first, kind: .blocked),
            QuotaNotificationKey(identity: second, kind: .warning),
            QuotaNotificationKey(identity: other, kind: .blocked),
        ]
        #expect(try await store.deliveredNotifications(day: fixture.day) == expected)
        // Reading must neither claim additional keys nor discard old rule versions.
        #expect(try await store.deliveredNotifications(day: fixture.day) == expected)
        let db = try SQLiteConnection(path: fixture.path)
        #expect(try db.query("SELECT DISTINCT kind FROM notification_receipts ORDER BY kind",
                             row: { $0.text(0) }) == ["exceeded", "warning"])
        #expect(try db.scalar("SELECT COUNT(*) FROM notification_receipts") == 6)
        try db.close()
        try await store.close()
        let reopened = try fixture.open()
        #expect(try await reopened.deliveredNotifications(day: fixture.day) == expected)
        for day in [previousDay, futureDay] {
            let identity = try QuotaIdentity(appKey: "signed:app", day: day, ruleVersion: 2)
            #expect(try await reopened.deliveredNotifications(day: day)
                    == [QuotaNotificationKey(identity: identity, kind: .blocked)])
        }
        try await reopened.prunePreviousDays()
        #expect(try await reopened.deliveredNotifications(day: previousDay).isEmpty)
        #expect(try await reopened.deliveredNotifications(day: fixture.day) == expected)
        #expect(try await reopened.deliveredNotifications(day: futureDay).isEmpty)
        try await reopened.close()
        await expectStoreError(.closed) { try await reopened.deliveredNotifications(day: fixture.day) }
    }

    @Test func rejectsInvalidDays() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        for day in ["", "2026-02-29", "2026-11-4", "2026-11-04\0", "0000-01-01"] {
            await expectStoreError(.invalidDay(day)) {
                try await store.deliveredNotifications(day: day)
            }
        }
        try await store.close()
    }
}
