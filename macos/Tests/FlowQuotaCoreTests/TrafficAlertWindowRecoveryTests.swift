import Testing
@testable import FlowQuotaCore

@Test func sourceRollbackRetainsOtherAppsAndUsesItsOwnObservedDuration() throws {
    var window = TrafficAlertWindow()
    _ = try window.consume([:], uptime: 1_000_000_000, scope: "s", windowSeconds: 180, continuous: false)
    _ = try window.consume(["reset": 120, "healthy": 120], uptime: 3_000_000_000,
                           scope: "s", windowSeconds: 180, continuous: true)
    let crossed = try window.consume(["reset": 80, "healthy": 130], uptime: 5_000_000_000,
        scope: "s", windowSeconds: 180, continuous: true, resetSources: ["reset"])
    #expect(crossed["reset"] == nil)
    #expect(crossed["healthy"]?.bytes == 250)
    #expect(crossed["healthy"]?.observedSeconds == 4)
    let resumed = try window.consume(["reset": 20], uptime: 7_000_000_000,
                                    scope: "s", windowSeconds: 180, continuous: true)
    #expect(resumed["reset"]?.bytes == 20)
    #expect(resumed["reset"]?.observedSeconds == 2)
    #expect(resumed["healthy"]?.bytes == 250)
    #expect(resumed["healthy"]?.observedSeconds == 6)
}

@Test func capacityIsCheckedOnEveryBaselineAndRecoveryWaitsForAValidInterval() throws {
    var window = TrafficAlertWindow()
    let tooMany = Dictionary(uniqueKeysWithValues: (0..<129).map { ("app\($0)", Int64(1)) })
    for tick in [1, 3, 5] {
        #expect(throws: TrafficAlertError.self) {
            try window.consume(tooMany, uptime: UInt64(tick) * 1_000_000_000,
                               scope: "s", windowSeconds: 180, continuous: true)
        }
        #expect(!window.isCollecting)
    }
    #expect(try window.consume(["ok": 100], uptime: 7_000_000_000,
                              scope: "s", windowSeconds: 180, continuous: true).isEmpty)
    #expect(!window.isCollecting)
    let result = try window.consume(["ok": 2], uptime: 9_000_000_000,
                                   scope: "s", windowSeconds: 180, continuous: true)
    #expect(result["ok"]?.bytes == 2)
    #expect(window.isCollecting)
}

@Test func bucketLimitReportsSamplingCapacityInsteadOfApplicationSourceCount() throws {
    var window = TrafficAlertWindow()
    _ = try window.consume([:], uptime: 1, scope: "s", windowSeconds: 60, continuous: false)
    for tick in 1...450 {
        _ = try window.consume(["interface": 1], uptime: UInt64(tick + 1),
                               scope: "s", windowSeconds: 60, continuous: true)
    }
    do {
        _ = try window.consume(["interface": 1], uptime: 452,
                               scope: "s", windowSeconds: 60, continuous: true)
        Issue.record("Expected bounded bucket capacity")
    } catch {
        guard case TrafficAlertError.bucketLimit = error else { throw error }
    }
    #expect(!window.isCollecting)
}
