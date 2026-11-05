import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaStore
@testable import FlowQuotaAgent

@Test func earnedEventSurvivesWindowExpiryAndConfigurationChangeSuppressesOldRetries() async throws {
    try await withRegressionRuntime { runtime, store, counter, path, url in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let day = try LocalDay.key(for: now, in: .current)
        let db = try SQLiteConnection(path: url.path)
        defer { try? db.close() }
        try db.execute("""
            CREATE TRIGGER fail_burst BEFORE INSERT ON traffic_alert_events
            WHEN NEW.kind = 'interfaceBurst' BEGIN SELECT RAISE(ABORT, 'temporary failure'); END
            """)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 1_000_000_000)
        counter.set(250_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now.addingTimeInterval(2), uptime: 3_000_000_000)
        #expect(try await runtime.snapshot().trafficAlertMessage.contains("将重试"))
        #expect(await runtime.trafficAlertWrites.count == 1)
        let original = try #require(await runtime.trafficAlertWrites.candidates(kind: .interfaceBurst).first)
        try db.execute("DROP TRIGGER fail_burst")
        await runtime.sampleInterface(path: path, generation: 0, now: now.addingTimeInterval(602), uptime: 603_000_000_000)
        #expect(try await store.trafficAlertEvents(day: day) == [original])
        #expect(await runtime.trafficAlertWrites.count == 0)
        try db.execute("""
            CREATE TRIGGER fail_burst BEFORE INSERT ON traffic_alert_events
            WHEN NEW.kind = 'interfaceBurst' BEGIN SELECT RAISE(ABORT, 'temporary failure'); END
            """)
        counter.set(500_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now.addingTimeInterval(604), uptime: 605_000_000_000)
        #expect(await runtime.trafficAlertWrites.count == 1)
        _ = try await runtime.handle(.saveTrafficAlertPolicy(try TrafficAlertPolicy(dailyInterfaceBytes: nil,
            interfaceBurstBytes: nil, applicationBurstBytes: nil, version: 2)))
        try db.execute("DROP TRIGGER fail_burst")
        await runtime.sampleInterface(path: path, generation: 0, now: now.addingTimeInterval(606), uptime: 607_000_000_000)
        #expect(try await store.trafficAlertEvents(day: day) == [original])
        #expect(await runtime.trafficAlertWrites.count == 0)
    }
}

@Test func oneApplicationWriteFailureDoesNotSkipOthersAndRetriesWithoutNewTraffic() async throws {
    try await withRegressionRuntime { runtime, store, _, _, url in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let day = try LocalDay.key(for: now, in: .current)
        let db = try SQLiteConnection(path: url.path)
        defer { try? db.close() }
        let increments = ["exec:/a", "exec:/b"].map {
            UsageIncrement(identity: AppIdentity(key: $0, name: $0), uploadedBytes: 0, downloadedBytes: 250_000_000)
        }
        try await store.recordSample(day: day, increments: increments)
        try db.execute("""
            CREATE TRIGGER fail_first_app BEFORE INSERT ON traffic_alert_events
            WHEN NEW.source_key = 'exec:/a' BEGIN SELECT RAISE(ABORT, 'one source failure'); END
            """)
        await runtime.evaluateApplicationAlerts([], day: day, continuous: false, pathGeneration: 7,
            generation: 0, now: now, uptime: 1_000_000_000)
        await runtime.evaluateApplicationAlerts(increments, day: day, continuous: true, pathGeneration: 7,
            generation: 0, now: now.addingTimeInterval(2), uptime: 3_000_000_000)
        #expect(try await store.trafficAlertEvents(day: day).map(\.sourceKey) == ["exec:/b"])
        let original = try #require(await runtime.trafficAlertWrites.candidates(kind: .applicationBurst).first)
        #expect(original.sourceKey == "exec:/a")
        try db.execute("DROP TRIGGER fail_first_app")
        await runtime.evaluateApplicationAlerts([], day: day, continuous: true, pathGeneration: 7,
            generation: 0, now: now.addingTimeInterval(4), uptime: 5_000_000_000)
        let events = try await store.trafficAlertEvents(day: day)
        #expect(Set(events.map(\.sourceKey)) == ["exec:/a", "exec:/b"])
        #expect(events.contains(original))
        #expect(await runtime.trafficAlertWrites.count == 0)
    }
}
