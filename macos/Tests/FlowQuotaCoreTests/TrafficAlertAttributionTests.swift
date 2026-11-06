import Foundation
import Testing
@testable import FlowQuotaCore

private let second: UInt64 = 1_000_000_000
private func app(_ name: String = "Browser", up: Int64 = 10, down: Int64 = 20) -> TrafficAlertApplication {
    TrafficAlertApplication(identity: AppIdentity(key: "signed:\(name)", name: name), uploadedBytes: up, downloadedBytes: down)
}
private func feed(_ window: inout TrafficAlertAttributionWindow, _ time: UInt64,
                  items: [TrafficAlertApplication] = [app()], scope: String = "day:network:policy",
                  reset: Set<String> = []) throws {
    try window.consume(items, uptime: time * second, observedAt: Date(timeIntervalSince1970: Double(1000 + time)),
        scope: scope, windowSeconds: 180, continuous: true, resetSources: reset)
}

@Test func attributionDiscardsPartialLeftAndFutureBucketsAndNeverMutatesBaseline() throws {
    var window = TrafficAlertAttributionWindow()
    try feed(&window, 1, items: [])
    try feed(&window, 3, items: [app(up: 10, down: 20)])
    try feed(&window, 5, items: [app(up: 30, down: 40)])
    let scope = "day:network:policy"
    let all = window.snapshot(since: second, through: 5 * second, scope: scope)
    #expect(all.items.first?.uploadedBytes == 40)
    #expect(all.items.first?.downloadedBytes == 60)
    let partial = window.snapshot(since: 2 * second, through: 5 * second, scope: scope)
    #expect(partial.items.first?.totalBytes == 70)
    let future = window.snapshot(since: second, through: 4 * second, scope: scope)
    #expect(future.items.first?.totalBytes == 30) // The later application frame is excluded.
    #expect(future.observedAt == Date(timeIntervalSince1970: 1003))
    #expect(window.snapshot(since: second, through: 5 * second, scope: scope) == all)
    #expect(window.snapshot(since: second, through: 14 * second, scope: scope).observedAt == nil)
}

@Test func attributionSeparatesScopeGapsZeroAndPerSourceRollback() throws {
    var window = TrafficAlertAttributionWindow()
    try feed(&window, 1, items: [])
    try feed(&window, 3, items: [app(), app("Helper")])
    try feed(&window, 5, items: [app(), app("Helper")], reset: ["signed:Helper"])
    let snapshot = window.snapshot(since: second, through: 5 * second, scope: "day:network:policy")
    #expect(snapshot.items.map(\.identity.name) == ["Browser"])
    #expect(snapshot.items.first?.totalBytes == 60)
    try feed(&window, 7, items: [], scope: "other-category")
    #expect(window.snapshot(since: second, through: 7 * second, scope: "day:network:policy").observedAt == nil)
    try feed(&window, 9, items: [], scope: "other-category")
    let zero = window.snapshot(since: 7 * second, through: 9 * second, scope: "other-category")
    #expect(zero.items.isEmpty && zero.observedAt != nil)
    try feed(&window, 19, items: [], scope: "other-category")
    #expect(window.snapshot(since: second, through: 19 * second, scope: "other-category").observedAt == nil)
}

@Test func attributionCapacityAndOverflowBecomeUnavailableAndRecoverFromNewBaseline() throws {
    var window = TrafficAlertAttributionWindow()
    try feed(&window, 1, items: [])
    #expect(throws: TrafficAlertError.sourceLimit) {
        try feed(&window, 3, items: (0..<129).map { app("\($0)") })
    }
    #expect(window.snapshot(since: second, through: 3 * second, scope: "day:network:policy").observedAt == nil)
    try feed(&window, 5, items: [])
    try feed(&window, 7)
    #expect(window.snapshot(since: 5 * second, through: 7 * second, scope: "day:network:policy").items.count == 1)
    #expect(throws: TrafficAlertError.self) { try feed(&window, 9, items: [app(up: .max, down: 1)]) }
}

@Test func summariesStayBoundedAndLegacyEventsDecodeWithoutInventedEvidence() throws {
    let applications = TrafficAlertApplications(items: (0..<128).map {
        app(String(repeating: "应", count: 70) + "\($0)", up: Int64($0 + 1), down: 1)
    }, observedAt: Date())
    try applications.validate()
    #expect(applications.summary.utf8.count <= 256)
    #expect(applications.summary.contains("128"))
    let event = TrafficAlertEvent(day: "2026-11-06", kind: .interfaceBurst, sourceName: "interface",
        observedBytes: 200, thresholdBytes: 100, windowSeconds: 180, observedSeconds: 2,
        policyVersion: 1, occurredAt: Date(), applications: applications)
    #expect(event.summaryOnly().applications == nil)
    #expect(event.summaryOnly().applicationSummary == applications.summary)
    let encoded = try JSONEncoder().encode(event.summaryOnly())
    #expect(encoded.count < 1500)
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json.removeValue(forKey: "applicationSummary")
    let old = try JSONDecoder().decode(TrafficAlertEvent.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.applications == nil && old.applicationSummary == nil)
    try old.validate()
}

@Test func attributionBoundsRetainedSourcesAndBucketsAcrossFrames() throws {
    var sources = TrafficAlertAttributionWindow()
    try feed(&sources, 1, items: [])
    for index in 0..<128 { try feed(&sources, UInt64(index + 2), items: [app("\(index)")]) }
    #expect(throws: TrafficAlertError.sourceLimit) { try feed(&sources, 130, items: [app("extra")]) }
    var buckets = TrafficAlertAttributionWindow()
    for index in 0...450 {
        try buckets.consume([], uptime: UInt64(index + 1) * 1_000_000, observedAt: Date(),
            scope: "same", windowSeconds: 180, continuous: true)
    }
    #expect(throws: TrafficAlertError.bucketLimit) {
        try buckets.consume([], uptime: 452_000_000, observedAt: Date(), scope: "same",
            windowSeconds: 180, continuous: true)
    }
}

@Test func detailedEvidenceAndMaximumHistoryPageStayInsideExistingIPCEnvelope() throws {
    let applications = TrafficAlertApplications(items: (0..<128).map { index in
        TrafficAlertApplication(identity: AppIdentity(key: "signed:" + String(repeating: "k", count: 1900) + "\(index)",
            name: String(repeating: "应", count: 75) + "\(index)"), uploadedBytes: Int64(index + 1), downloadedBytes: .max / 2)
    }, observedAt: Date())
    try applications.validate()
    let events = (0..<256).map { _ in
        TrafficAlertEvent(day: "2026-11-06", kind: .interfaceBurst, sourceName: "interface",
            observedBytes: .max, thresholdBytes: 100, windowSeconds: 180, observedSeconds: 2,
            policyVersion: 1, occurredAt: Date(), applications: applications)
    }
    let detail = try JSONEncoder().encode(AgentReply.trafficAlertDetails(events[0]))
    #expect(detail.count < AgentEndpoint.maximumMessageBytes)
    let page = try JSONEncoder().encode(AgentReply.trafficAlertHistory(Array(events.prefix(32)).map { $0.summaryOnly() }))
    #expect(page.count < AgentEndpoint.maximumMessageBytes / 8)
    let snapshot = AgentSnapshot(generatedAt: Date(), network: .expensive, readiness: .notInstalled,
        applications: [], message: "simulated", trafficAlertEvents: events.map { $0.summaryOnly() },
        pendingTrafficAlerts: Array(events.prefix(16)).map { $0.summaryOnly() })
    let encoded = try JSONEncoder().encode(AgentReply.snapshot(snapshot))
    #expect(encoded.count < AgentEndpoint.maximumMessageBytes / 2)
}
