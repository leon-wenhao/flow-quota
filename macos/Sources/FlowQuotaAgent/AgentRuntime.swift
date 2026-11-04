import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import FlowQuotaStore

actor AgentRuntime {
    private let store: QuotaStore
    private let network = NetworkObserver()
    private var lastPrunedDay: String?

    init(store: QuotaStore) { self.store = store }

    func handle(_ request: AgentRequest) async throws -> AgentReply {
        switch request {
        case .snapshot:
            let path = network.snapshot()
            let day = try LocalDay.key(for: Date(), in: .current)
            if day != lastPrunedDay {
                try await store.prunePreviousDays()
                lastPrunedDay = day
            }
            let rows = try await store.snapshot(day: day)
            return .snapshot(AgentSnapshot(
                generatedAt: Date(), network: path.state, readiness: .notInstalled,
                applications: rows,
                message: "真实过滤扩展尚未就绪，当前不提供流量计量或阻断。" + path.message
            ))
        case .saveRule:
            // A database write is not an engine ACK. Refuse rather than promise
            // protection until the real extension can consume and confirm rules.
            throw PlatformError.unavailable("过滤扩展尚未就绪，无法确认规则生效；原规则保持不变。")
        case .setHotspotOverride(let marked):
            try network.markCurrentPath(marked)
            return .acknowledged
        case .stopProtection:
            // No extension is registered by this development build, so there are
            // no installed filters to release. Replace only with verified engine ACK.
            return .acknowledged
        }
    }

}
