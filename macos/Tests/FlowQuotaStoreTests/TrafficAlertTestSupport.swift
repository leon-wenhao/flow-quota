import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

extension StoreFixture {
    func alert(id: String = UUID().uuidString, day: String? = nil, kind: TrafficAlertKind = .interfaceBurst,
               source: String = "", name: String = "Physical interface", observed: Int64? = nil,
               threshold: Int64? = nil, window: Int? = nil, seconds: Int? = nil, version: Int64 = 1,
               at: Date? = nil, scheduled: Date? = nil) -> TrafficAlertEvent {
        let threshold = threshold ?? TrafficAlertPolicy.initial.threshold(for: kind)!
        return TrafficAlertEvent(id: id, day: day ?? self.day, kind: kind, sourceKey: source, sourceName: name,
            observedBytes: observed ?? threshold, thresholdBytes: threshold,
            windowSeconds: window ?? (kind == .dailyInterface ? 0 : TrafficAlertPolicy.initial.windowSeconds),
            observedSeconds: seconds ?? (kind == .dailyInterface ? 0 : 10), policyVersion: version,
            occurredAt: at ?? clock.now(), scheduledAt: scheduled)
    }
}

func alertPolicy(version: Int64 = 2, daily: Int64? = 100, burst: Int64? = 100,
                 app: Int64? = 100, window: Int = 60, cooldown: Int = 60) throws -> TrafficAlertPolicy {
    try TrafficAlertPolicy(dailyInterfaceBytes: daily, interfaceBurstBytes: burst, applicationBurstBytes: app,
                           windowSeconds: window, cooldownSeconds: cooldown, version: version)
}

func expectAlertError<T>(_ expected: TrafficAlertError, _ operation: () async throws -> T,
                         sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        _ = try await operation()
        Issue.record("Expected \(expected)", sourceLocation: sourceLocation)
    } catch {
        #expect(error is TrafficAlertError, sourceLocation: sourceLocation)
        #expect(String(describing: error) == String(describing: expected), sourceLocation: sourceLocation)
    }
}

// Deliberately bypass throwing initializers to test Codable trust boundaries.
func decodedMutation<T: Codable>(_ value: T, field: String, replacement: Any) throws -> T {
    let data = try JSONEncoder().encode(value)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object[field] = replacement
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
