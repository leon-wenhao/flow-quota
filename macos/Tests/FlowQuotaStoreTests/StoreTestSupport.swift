import Foundation
import Testing
@testable import FlowQuotaStore
import FlowQuotaCore

struct StoreFixture {
    let directory: URL
    var path: String { directory.appendingPathComponent("quota.sqlite").path }
    let clock = TestClock()
    let calendar: Calendar
    var day: String { try! StoreDay.label(at: clock.now(), calendar: calendar) }
    var expiry: Date { clock.now().addingTimeInterval(60) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FlowQuotaStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = utc
    }

    func open() throws -> QuotaStore {
        try QuotaStore(path: path, clock: { clock.now() }, calendar: calendar)
    }

    func seed(_ store: QuotaStore, limit: Int64? = 100, key: String = "signed:app") async throws {
        try await store.registerApplication(AppIdentity(key: key, name: "Application"))
        try await store.saveRule(appKey: key, rule: QuotaRule(limitBytes: limit))
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Test-only injected time, protected because reservations execute across actors.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_793_793_600) // 2026-11-04 12:00 UTC
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

func expectStoreError<T>(_ expected: StoreError,
                         _ operation: () async throws -> T,
                         sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        _ = try await operation()
        Issue.record("Expected \(expected)", sourceLocation: sourceLocation)
    } catch {
        #expect(error as? StoreError == expected, sourceLocation: sourceLocation)
    }
}
