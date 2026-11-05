import Foundation
import Testing
@testable import FlowQuotaCore

@Test func trafficWindowCanWarnEarlyAtTwelveGigabytesWithoutRealTraffic() throws {
    var window = TrafficAlertWindow()
    #expect(try window.consume([:], uptime: 1_000_000_000, scope: "today:1", windowSeconds: 300,
                               continuous: false).isEmpty)
    let measured = try window.consume(["interface": 12_000_000_000], uptime: 3_000_000_000,
                                      scope: "today:1", windowSeconds: 300, continuous: true)
    #expect(measured["interface"]?.bytes == 12_000_000_000)
    #expect(measured["interface"]?.observedSeconds == 2)
}

@Test func rollingWindowsDiscardPartialBoundaryBucketsInsteadOfEstimatingBytes() throws {
    var window = TrafficAlertWindow()
    _ = try window.consume([:], uptime: 1_000_000_000, scope: "s", windowSeconds: 60, continuous: false)
    for tick in 1...30 {
        _ = try window.consume(["app": 10], uptime: UInt64(1 + tick * 2) * 1_000_000_000,
                               scope: "s", windowSeconds: 60, continuous: true)
    }
    let next = try window.consume(["app": 1], uptime: 62_000_000_000,
                                  scope: "s", windowSeconds: 60, continuous: true)
    #expect(next["app"]?.bytes == 291)
    #expect(next["app"]?.observedSeconds == 59)
}

@Test func gapsPathDayAndPolicyChangesNeverBridgeBurstWindows() throws {
    for transition in ["path", "day", "policy", "gap", "reset", "backwards"] {
        var window = TrafficAlertWindow()
        _ = try window.consume([:], uptime: 1_000_000_000, scope: "first", windowSeconds: 300, continuous: false)
        _ = try window.consume(["a": 100], uptime: 3_000_000_000, scope: "first", windowSeconds: 300, continuous: true)
        let scope = ["path", "day", "policy"].contains(transition) ? transition : "first"
        let time: UInt64 = transition == "gap" ? 20_000_000_000 : transition == "backwards" ? 2_000_000_000 : 5_000_000_000
        #expect(try window.consume(["a": 999], uptime: time, scope: scope,
                                   windowSeconds: 300, continuous: transition != "reset").isEmpty)
        let measured = try window.consume(["a": 2], uptime: time + 2_000_000_000,
                                          scope: scope, windowSeconds: 300, continuous: true)
        #expect(measured["a"]?.bytes == 2)
    }
}

@Test func applicationWindowsDoNotSumDifferentSourcesAndBoundMemory() throws {
    var window = TrafficAlertWindow()
    _ = try window.consume([:], uptime: 1, scope: "s", windowSeconds: 300, continuous: false)
    let result = try window.consume(["proxy": 100, "wallpaper": 100], uptime: 2_000_000_001,
                                    scope: "s", windowSeconds: 300, continuous: true)
    #expect(result["proxy"]?.bytes == 100)
    #expect(result["wallpaper"]?.bytes == 100)
    #expect(throws: TrafficAlertError.self) {
        try window.consume(Dictionary(uniqueKeysWithValues: (0...128).map { ("app\($0)", Int64(1)) }),
                           uptime: 4_000_000_001, scope: "s", windowSeconds: 300, continuous: true)
    }
    #expect(try window.consume(["new": 999], uptime: 6_000_000_001, scope: "s", windowSeconds: 300,
                               continuous: true).isEmpty)
}

@Test func alertWindowOverflowClearsStateAndDisabledThresholdsAreValid() throws {
    var window = TrafficAlertWindow()
    _ = try window.consume([:], uptime: 1, scope: "s", windowSeconds: 300, continuous: false)
    _ = try window.consume(["a": Int64.max], uptime: 2_000_000_001, scope: "s", windowSeconds: 300, continuous: true)
    #expect(throws: TrafficAlertError.self) {
        try window.consume(["a": 1], uptime: 4_000_000_001, scope: "s", windowSeconds: 300, continuous: true)
    }
    let off = try TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: nil,
                                    applicationBurstBytes: nil, version: 2)
    #expect(TrafficAlertKind.allCases.allSatisfy { off.threshold(for: $0) == nil })
    #expect(throws: TrafficAlertError.self) {
        try TrafficAlertPolicy(dailyInterfaceBytes: 0, interfaceBurstBytes: nil, applicationBurstBytes: nil, version: 1)
    }
}
