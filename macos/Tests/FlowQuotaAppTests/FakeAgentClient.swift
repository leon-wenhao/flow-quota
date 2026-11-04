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
    var savedRules = 0
    var marked: Bool?

    init(readiness: ProtectionReadiness = .notInstalled, date: Date = Date(),
         applications: [ApplicationSnapshot] = []) {
        state = AgentSnapshot(generatedAt: date, network: .unknown, readiness: readiness,
                              applications: applications, message: "Test service")
    }
    func enableAgent() async throws {}
    func repairDevelopmentAgent() async throws {}
    func fetchSnapshot() async throws -> AgentSnapshot {
        if fetchFails { throw PlatformError.unavailable("test connection failure") }
        return state
    }
    func saveRule(appKey: String, rule: QuotaRule) async throws {
        if saveFails { throw PlatformError.unavailable("test save rejected") }
        savedRules += 1
    }
    func setHotspotOverride(_ marked: Bool) async throws { self.marked = marked }
    func stopProtection() async throws {
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
