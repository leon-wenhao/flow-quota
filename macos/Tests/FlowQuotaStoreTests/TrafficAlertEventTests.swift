import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

struct TrafficAlertEventTests {
    @Test func cooldownSurvivesRestartAndBackwardsOccurrence() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let start = fixture.clock.now()
        #expect(try await store.recordTrafficAlert(fixture.alert()))
        fixture.clock.advance(600)
        #expect(try await store.recordTrafficAlert(fixture.alert()))
        try await store.close()
        let reopened = try fixture.open()
        fixture.clock.advance(-1_200)
        #expect(try await !reopened.recordTrafficAlert(fixture.alert())) // behind the persisted maximum
        fixture.clock.advance(1_799.999)
        #expect(try await !reopened.recordTrafficAlert(fixture.alert())) // 599999ms since latest
        fixture.clock.advance(0.001)
        #expect(try await reopened.recordTrafficAlert(fixture.alert())) // exact 600s boundary
        let events = try await reopened.trafficAlertEvents(day: fixture.day)
        #expect(events.count == 3)
        #expect(events.last?.occurredAt == start)
        try await reopened.close()
    }

    @Test func dailyOncePerVersionAndIndependentAppSourcesWithoutForeignKeys() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        #expect(try await store.recordTrafficAlert(fixture.alert(kind: .dailyInterface)))
        fixture.clock.advance(1_000)
        #expect(try await !store.recordTrafficAlert(fixture.alert(kind: .dailyInterface)))
        for key in ["signed:a", "process:background"] {
            #expect(try await store.recordTrafficAlert(fixture.alert(kind: .applicationBurst, source: key)))
            #expect(try await !store.recordTrafficAlert(fixture.alert(kind: .applicationBurst, source: key)))
        }
        try await store.saveTrafficAlertPolicy(alertPolicy())
        #expect(try await store.recordTrafficAlert(fixture.alert(kind: .dailyInterface, threshold: 100, version: 2)))
        #expect(try await store.snapshot(day: fixture.day).isEmpty)
        let db = try SQLiteConnection(path: fixture.path)
        #expect(try db.query("PRAGMA foreign_key_list(traffic_alert_events)", row: { $0.text(0) }).isEmpty)
        try db.close(); try await store.close()
    }

    @Test func offStaleVersionThresholdAndWindowAreSuppressed() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await store.saveTrafficAlertPolicy(alertPolicy())
        for event in [fixture.alert(), fixture.alert(threshold: 101, window: 60, version: 2),
                      fixture.alert(threshold: 100, window: 61, version: 2)] {
            #expect(try await !store.recordTrafficAlert(event))
        }
        #expect(try await store.recordTrafficAlert(fixture.alert(threshold: 100, window: 60, version: 2)))
        try await store.saveTrafficAlertPolicy(alertPolicy(version: 3, daily: nil, burst: nil, app: nil))
        for kind in TrafficAlertKind.allCases {
            let event = fixture.alert(kind: kind, source: kind == .applicationBurst ? "signed:a" : "",
                                      threshold: 100, window: kind == .dailyInterface ? 0 : 60, version: 3)
            #expect(try await !store.recordTrafficAlert(event))
        }
        #expect(try await store.trafficAlertEvents(day: fixture.day).count == 1)
        try await store.close()
    }

    @Test func exactUUIDRetryConflictsAndACKAreDurable() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let event = fixture.alert(id: id.lowercased())
        #expect(try await store.recordTrafficAlert(event))
        #expect(try await !store.recordTrafficAlert(event))
        await expectStoreError(.trafficAlertConflict) {
            try await store.recordTrafficAlert(fixture.alert(id: id, observed: event.observedBytes + 1))
        }
        fixture.clock.advance(1.234)
        try await store.acknowledgeTrafficAlert(id: id, day: fixture.day)
        let scheduled = fixture.clock.now()
        fixture.clock.advance(10)
        try await store.acknowledgeTrafficAlert(id: id.lowercased(), day: fixture.day)
        #expect(try await !store.recordTrafficAlert(event))
        try await store.close()
        let reopened = try fixture.open()
        let saved = try #require(try await reopened.trafficAlertEvents(day: fixture.day).first)
        #expect(saved.id == id)
        #expect(saved.scheduledAt == scheduled)
        #expect(try await !reopened.recordTrafficAlert(saved))
        #expect(try await !reopened.recordTrafficAlert(event))
        await expectStoreError(.trafficAlertConflict) {
            try await reopened.recordTrafficAlert(fixture.alert(id: id, at: event.occurredAt,
                scheduled: scheduled.addingTimeInterval(1)))
        }
        try await reopened.close()
    }

    @Test func ackRejectsUnknownStaleDayAndBackwardsClock() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let event = fixture.alert()
        #expect(try await store.recordTrafficAlert(event))
        let missing = UUID().uuidString
        await expectStoreError(.unknownTrafficAlert(missing)) {
            try await store.acknowledgeTrafficAlert(id: missing, day: fixture.day)
        }
        fixture.clock.advance(-1)
        await expectAlertError(.invalidEvent) { try await store.acknowledgeTrafficAlert(id: event.id, day: event.day) }
        fixture.clock.advance(1)
        try await store.saveTrafficAlertPolicy(alertPolicy())
        await expectStoreError(.staleTrafficAlertPolicy) {
            try await store.acknowledgeTrafficAlert(id: event.id, day: event.day)
        }
        fixture.clock.advance(86_400)
        await expectStoreError(.inactiveDay) { try await store.acknowledgeTrafficAlert(id: event.id, day: event.day) }
        #expect(try await store.trafficAlertEvents(day: event.day).first?.scheduledAt == nil)
        try await store.close()
    }

    @Test func eventsValidateCodableAndStorageBoundaries() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let base = fixture.alert()
        let fields: [(String, Any)] = [
            ("id", "bad"), ("day", "2026-02-29"), ("sourceName", " \n\t"),
            ("sourceName", "a\0b"), ("sourceName", String(repeating: "字", count: 86)),
            ("sourceKey", "unexpected"), ("observedBytes", 0), ("thresholdBytes", 0),
            ("windowSeconds", 59), ("windowSeconds", 901), ("observedSeconds", 0),
            ("observedSeconds", 301), ("policyVersion", 0)]
        for (field, value) in fields {
            let event = try decodedMutation(base, field: field, replacement: value)
            await expectAlertError(.invalidEvent) { try await store.recordTrafficAlert(event) }
        }
        for key in ["   ", "signed:e\u{301}", String(repeating: "x", count: 2049), "x\0y"] {
            await expectAlertError(.invalidEvent) {
                try await store.recordTrafficAlert(fixture.alert(kind: .applicationBurst, source: key))
            }
        }
        for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
                     Date(timeIntervalSince1970: 0.0001), Date(timeIntervalSince1970: 253_402_300_800)] {
            await expectAlertError(.invalidEvent) { try await store.recordTrafficAlert(fixture.alert(at: date)) }
        }
        await expectAlertError(.invalidEvent) {
            try await store.recordTrafficAlert(fixture.alert(scheduled: fixture.clock.now()))
        }
        let yesterday = fixture.clock.now().addingTimeInterval(-86_400)
        let yesterdayKey = try StoreDay.label(at: yesterday, calendar: fixture.calendar)
        await expectAlertError(.invalidEvent) { try await store.recordTrafficAlert(fixture.alert(at: yesterday)) }
        await expectStoreError(.inactiveDay) {
            try await store.recordTrafficAlert(fixture.alert(day: yesterdayKey, at: yesterday))
        }
        #expect(try await store.trafficAlertEvents(day: fixture.day).isEmpty)
        try await store.close()
    }

    @Test func millisecondRetryDoesNotDriftAndNamesCompareExactBytes() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let event = fixture.alert(name: "e\u{301}", at: fixture.clock.now().addingTimeInterval(0.1234))
        #expect(try await store.recordTrafficAlert(event))
        #expect(try await !store.recordTrafficAlert(event))
        let loaded = try #require(try await store.trafficAlertEvents(day: fixture.day).first)
        #expect(try await !store.recordTrafficAlert(loaded))
        await expectStoreError(.trafficAlertConflict) {
            try await store.recordTrafficAlert(fixture.alert(id: event.id, name: "é", at: event.occurredAt))
        }
        try await store.close()
    }
}
