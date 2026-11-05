import Darwin
import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaPlatform
@testable import FlowQuotaStore
@testable import FlowQuotaAgent

@Test func interfaceDefaultClockMustSeparateSleepFromBurstWindow() async throws {
    try await withRegressionRuntime { runtime, store, counter, path, _ in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let day = try LocalDay.key(for: now, in: .current)
        await runtime.sampleInterface(path: path, generation: 0, now: now)
        counter.set(120_000_000)
        counter.setTime(3_000_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now.addingTimeInterval(2))
        // Continuous time includes the simulated 10-minute sleep; callers use the
        // injected default clock rather than manually supplying an uptime value.
        counter.set(210_000_000)
        counter.setTime(605_000_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now.addingTimeInterval(604))
        let events = try await store.trafficAlertEvents(day: day)
        #expect(events.isEmpty, "A 600-second unknown gap must clear the 180-second burst window")
        #expect(try await store.interfaceUsage(day: day)?.totalBytes == 120_000_000)
        counter.set(220_000_000)
        counter.setTime(607_000_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now.addingTimeInterval(606))
        #expect(try await store.interfaceUsage(day: day)?.totalBytes == 130_000_000)
    }
}

@Test func unrelatedCounterRollbackMustPreserveHealthyApplicationBurst() async throws {
    try await withRegressionRuntime { runtime, store, _, _, _ in
        let pid = getpid()
        let child = Process()
        let input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let otherPID = child.processIdentifier
        let resolver = ProcessIdentityResolver()
        let zero = ProcessCounter(pid: pid, uploadedBytes: 0, downloadedBytes: 0)
        let other = ProcessCounter(pid: otherPID, uploadedBytes: 0, downloadedBytes: 100)
        let ownIdentity = try #require(resolver.resolve(zero)?.identity)
        let otherIdentity = try #require(resolver.resolve(other)?.identity)
        try #require(ownIdentity.key != otherIdentity.key)
        let day = try LocalDay.key(for: Date(), in: .current)
        for (tick, ownBytes, otherBytes) in [(1, Int64(0), Int64(100)), (3, 120_000_000, 200), (5, 250_000_000, 50)] {
            let frame = NettopFrame(sequence: UInt64((tick + 1) / 2), capturedAt: Date(), uptime: UInt64(tick) * 1_000_000_000,
                counters: [ProcessCounter(pid: pid, uploadedBytes: 0, downloadedBytes: ownBytes),
                           ProcessCounter(pid: otherPID, uploadedBytes: 0, downloadedBytes: otherBytes)])
            try await runtime.ingest(frame, generation: 0)
        }
        let usage = try #require(try await store.snapshot(day: day).first { $0.identity.key == ownIdentity.key })
        let events = try await store.trafficAlertEvents(day: day)
        #expect(usage.usage.totalBytes == 250_000_000)
        #expect(events.contains { $0.kind == .applicationBurst && $0.sourceKey == ownIdentity.key },
                "An unrelated counter reset must not discard a fully observed 250 MB application burst")
    }
}

@Test func persistentSourceLimitMustRemainVisibleOnEveryFrame() async throws {
    try await withRegressionRuntime { runtime, _, _, _, _ in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let day = try LocalDay.key(for: now, in: .current)
        let deltas = (0..<129).map { UsageIncrement(identity: AppIdentity(key: "exec:/audit-\($0)", name: "audit-\($0)"),
                                                   uploadedBytes: 0, downloadedBytes: 1) }
        await runtime.evaluateApplicationAlerts([], day: day, continuous: false, pathGeneration: 7,
                                                generation: 0, now: now, uptime: 1_000_000_000)
        for tick in [3, 5, 7] {
            await runtime.evaluateApplicationAlerts(deltas, day: day, continuous: true, pathGeneration: 7,
                                                    generation: 0, now: now, uptime: UInt64(tick) * 1_000_000_000)
            let snapshot = try await runtime.snapshot()
            #expect(snapshot.trafficAlertMessage.contains("覆盖不完整"), "Persistent source overflow must stay visible")
        }
        await runtime.evaluateApplicationAlerts([], day: day, continuous: true, pathGeneration: 7,
                                                generation: 0, now: now, uptime: 9_000_000_000)
        #expect(try await runtime.snapshot().trafficAlertMessage.contains("应用短时预警等待连续采样"))
        await runtime.evaluateApplicationAlerts([], day: day, continuous: true, pathGeneration: 7,
                                                generation: 0, now: now, uptime: 11_000_000_000)
        #expect(try await runtime.snapshot().trafficAlertMessage.contains("应用短时预警运行中"))
    }
}

@Test func dailyEventWriteFailureMustNotPreventIndependentBurstCheck() async throws {
    try await withRegressionRuntime { runtime, store, counter, path, url in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let day = try LocalDay.key(for: now, in: .current)
        let db = try SQLiteConnection(path: url.path)
        defer { try? db.close() }
        try db.execute("""
            CREATE TRIGGER audit_fail_daily BEFORE INSERT ON traffic_alert_events
            WHEN NEW.kind = 'dailyInterface' BEGIN SELECT RAISE(ABORT, 'daily only failure'); END
            """)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 1_000_000_000)
        counter.set(1_200_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 3_000_000_000)
        let events = try await store.trafficAlertEvents(day: day)
        #expect(events.contains { $0.kind == .interfaceBurst }, "Daily-only event failure must not skip the independent burst check")
    }
}

@Test func defaultCooldownDoesNotRepeatACompletedIsolatedBurst() async throws {
    try await withRegressionRuntime { runtime, store, _, _, _ in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let day = try LocalDay.key(for: now, in: .current)
        await runtime.evaluateInterfaceAlerts(day: day, uploaded: 0, downloaded: 0, continuous: false,
            pathGeneration: 7, generation: 0, now: now, uptime: 1_000_000_000)
        for tick in stride(from: 3, through: 605, by: 2) {
            await runtime.evaluateInterfaceAlerts(day: day, uploaded: 0, downloaded: tick == 3 ? 250_000_000 : 0,
                continuous: true, pathGeneration: 7, generation: 0, now: now.addingTimeInterval(Double(tick)),
                uptime: UInt64(tick) * 1_000_000_000)
        }
        #expect(try await store.trafficAlertEvents(day: day).filter { $0.kind == .interfaceBurst }.count == 1)
    }
}

@Test func sustainedBurstRepeatsOnlyAfterCooldown() async throws {
    try await withRegressionRuntime { runtime, store, _, _, _ in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let day = try LocalDay.key(for: now, in: .current)
        await runtime.evaluateInterfaceAlerts(day: day, uploaded: 0, downloaded: 0, continuous: false,
            pathGeneration: 7, generation: 0, now: now, uptime: 1_000_000_000)
        for tick in stride(from: 3, through: 605, by: 2) {
            await runtime.evaluateInterfaceAlerts(day: day, uploaded: 0, downloaded: 250_000_000, continuous: true,
                pathGeneration: 7, generation: 0, now: now.addingTimeInterval(Double(tick)), uptime: UInt64(tick) * 1_000_000_000)
        }
        let events = try await store.trafficAlertEvents(day: day).filter { $0.kind == .interfaceBurst }.sorted { $0.occurredAt < $1.occurredAt }
        #expect(events.count == 2)
        #expect(events[1].occurredAt.timeIntervalSince(events[0].occurredAt) == 600)
    }
}

@Test func transientEventWriteFailureRetriesOriginalBurstAfterRecovery() async throws {
    try await withRegressionRuntime { runtime, store, counter, path, url in
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let day = try LocalDay.key(for: now, in: .current)
        let db = try SQLiteConnection(path: url.path)
        defer { try? db.close() }
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 1_000_000_000)
        counter.set(120_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now.addingTimeInterval(2), uptime: 3_000_000_000)
        try db.execute("""
            CREATE TRIGGER audit_fail_burst BEFORE INSERT ON traffic_alert_events
            WHEN NEW.kind = 'interfaceBurst' BEGIN SELECT RAISE(ABORT, 'temporary failure'); END
            """)
        counter.set(210_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now.addingTimeInterval(4), uptime: 5_000_000_000)
        try db.execute("DROP TRIGGER audit_fail_burst")
        for tick in [7, 9] {
            await runtime.sampleInterface(path: path, generation: 0, now: now.addingTimeInterval(Double(tick - 1)),
                                         uptime: UInt64(tick) * 1_000_000_000)
        }
        let events = try await store.trafficAlertEvents(day: day)
        #expect(events.contains { $0.kind == .interfaceBurst }, "A known qualifying burst must retry after temporary event insertion failure")
        let event = try #require(events.first)
        #expect(event.observedBytes == 210_000_000)
        #expect(event.occurredAt == now.addingTimeInterval(4))
        #expect(await runtime.trafficAlertWrites.count == 0)
    }
}
