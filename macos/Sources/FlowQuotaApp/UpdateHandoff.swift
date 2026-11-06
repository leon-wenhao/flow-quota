import Foundation
import FlowQuotaPlatform

/// Runs only after the user confirms installation. A failed step never releases
/// Sparkle's continuation; retries retain the original sampling intent.
@MainActor final class UpdateHandoff {
    private let service: any UpdateAgentService
    private let store: UpdateResumeStore
    private let build: String
    private(set) var ready = false

    init(service: any UpdateAgentService = AgentClient(), store: UpdateResumeStore = .init(),
         build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") {
        self.service = service
        self.store = store
        self.build = build
    }

    var hasRecovery: Bool { store.hasPendingInstallation }

    func prepare(targetBuild: String) async throws {
        if let pending = try store.read() {
            guard pending.sourceBuild == build, pending.targetBuild == targetBuild else {
                throw PlatformError.unavailable("上一次更新尚未恢复，请先处理恢复状态。")
            }
        } else {
            let registered = try service.isRegisteredForUpdate()
            let status = registered ? try await service.fetchSnapshot().monitoring : nil
            try store.save(UpdateResumeRecord(sourceBuild: build, targetBuild: targetBuild,
                registered: registered, resumeSampling: registered && status != .paused))
        }
        if try service.isRegisteredForUpdate() {
            try await service.stopProtection()
            try await service.unregisterForUpdate()
        }
        ready = true
    }

    func recover(allowStale: Bool = false) async throws {
        guard let record = try store.read() else { return }
        guard allowStale || record.permitsAutomaticRecovery(build: build) else {
            throw PlatformError.unavailable("更新恢复标记已过期或与当前版本不匹配，未自动恢复采集。请手动恢复或清除标记。")
        }
        ready = false
        if record.registered {
            try await service.restoreAfterUpdate(resumeSampling: record.resumeSampling)
        }
        try store.clear()
    }

    func discardKeepingPaused() async throws {
        if try service.isRegisteredForUpdate() { try await service.stopProtection() }
        try store.clear()
        ready = false
    }
}
