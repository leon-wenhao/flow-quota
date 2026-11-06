import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import Testing
@testable import FlowQuotaApp

/// Test-only service substitute. No fake traffic is linked into the production app.
@MainActor final class FakeAgentClient: AgentServiceClient {
    var state: AgentSnapshot
    var fetchFails = false
    var saveFails = false
    var stopFails = false
    var holdStop = false
    var stopGate: CheckedContinuation<Void, Never>?
    var recoveringStop = false
    var savedRules = 0
    var acknowledgementFails = false
    var acknowledgements: [QuotaNotificationKey] = []
    var alertAcknowledgements: [String] = []
    var historyOffsets: [Int] = []
    var holdAlertPolicySave = false
    var alertPolicySaveGate: CheckedContinuation<Void, Never>?
    var savedAlertPolicy: TrafficAlertPolicy?
    var fetchCount = 0
    var enabledCount = 0
    var stoppedCount = 0
    var marked: Bool?
    var ruleCategories: [TrafficCategory] = []
    var policyCategories: [TrafficCategory] = []
    var historyCategories: [TrafficCategory] = []

    init(readiness: ProtectionReadiness = .notInstalled, date: Date = Date(),
         applications: [ApplicationSnapshot] = [], monitoring: MonitoringStatus = .unavailable,
         sampledAt: Date? = nil, notifications: [ReminderNotification] = [], network: NetworkState = .unknown,
         interfaceUsage: InterfaceUsage? = nil, interfaceSampledAt: Date? = nil,
         interfaceMessage: String = "接口总量尚未就绪。") {
        state = AgentSnapshot(generatedAt: date, network: network, readiness: readiness,
                              applications: applications, message: "Test service", monitoring: monitoring,
                              sampledAt: sampledAt, notifications: notifications,
                              interfaceUsage: interfaceUsage, interfaceSampledAt: interfaceSampledAt,
                              interfaceMessage: interfaceMessage)
    }
    func enableAgent() async throws { enabledCount += 1 }
    func repairDevelopmentAgent() async throws {}
    func fetchSnapshot() async throws -> AgentSnapshot {
        fetchCount += 1
        if fetchFails { throw PlatformError.unavailable("test connection failure") }
        return state
    }
    func saveRule(appKey: String, rule: QuotaRule) async throws {
        if saveFails { throw PlatformError.unavailable("test save rejected") }
        savedRules += 1
    }
    func saveRule(appKey: String, rule: QuotaRule, category: TrafficCategory) async throws {
        ruleCategories.append(category)
        try await saveRule(appKey: appKey, rule: rule)
    }
    func saveTrafficAlertPolicy(_ policy: TrafficAlertPolicy, category: TrafficCategory) async throws {
        policyCategories.append(category)
        try await saveTrafficAlertPolicy(policy)
    }
    func fetchTrafficAlertHistory(day: String, offset: Int, category: TrafficCategory) async throws -> [TrafficAlertEvent] {
        historyCategories.append(category)
        if let data = state.usage(for: category) {
            historyOffsets.append(offset)
            return Array(data.trafficAlertEvents.filter { $0.day == day }.dropFirst(offset).prefix(32))
        }
        return try await fetchTrafficAlertHistory(day: day, offset: offset)
    }
    func setHotspotOverride(_ marked: Bool) async throws { self.marked = marked }
    func acknowledgeNotification(_ key: QuotaNotificationKey) async throws {
        if acknowledgementFails { throw PlatformError.unavailable("test ACK failure") }
        acknowledgements.append(key)
    }
    func fetchTrafficAlertHistory(day: String, offset: Int) async throws -> [TrafficAlertEvent] {
        historyOffsets.append(offset)
        return Array(state.trafficAlertEvents.filter { $0.day == day }.dropFirst(offset).prefix(32))
    }
    func saveTrafficAlertPolicy(_ policy: TrafficAlertPolicy) async throws {
        if holdAlertPolicySave {
            await withCheckedContinuation { alertPolicySaveGate = $0 }
        }
        if saveFails { throw PlatformError.unavailable("test save rejected") }
        savedAlertPolicy = policy
    }
    func acknowledgeTrafficAlert(id: String) async throws {
        if acknowledgementFails { throw PlatformError.unavailable("test ACK failure") }
        alertAcknowledgements.append(id)
    }
    func stopForTermination(onRecovery: @escaping @MainActor () -> Void) async throws {
        if recoveringStop { onRecovery() }
        try await stopProtection()
    }
    func stopProtection() async throws {
        stoppedCount += 1
        if holdStop { await withCheckedContinuation { stopGate = $0 } }
        if stopFails { throw PlatformError.unavailable("test stop rejected") }
    }
}

@MainActor func finishOperation(_ state: AppState) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while state.busy && ContinuousClock.now < deadline { await Task.yield() }
    #expect(!state.busy)
}

func application(used: Int64 = 0) throws -> ApplicationSnapshot {
    ApplicationSnapshot(identity: AppIdentity(key: "signed.test", name: "Test app"),
        rule: try QuotaRule(limitBytes: 100, version: 1),
        usage: DailyUsage(appKey: "signed.test", day: try LocalDay.key(for: Date(), in: .current),
                          uploadedBytes: used, downloadedBytes: 0))
}

func interfaceUsage(uploaded: Int64 = 120, downloaded: Int64 = 80, day: String? = nil) throws -> InterfaceUsage {
    let currentDay = try LocalDay.key(for: Date(), in: .current)
    return InterfaceUsage(day: day ?? currentDay, uploadedBytes: uploaded, downloadedBytes: downloaded)
}
