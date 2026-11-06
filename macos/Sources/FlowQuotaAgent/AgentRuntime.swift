import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import FlowQuotaStore

/// The service owns sampling and storage even while the menu panel is hidden.
actor AgentRuntime {
    let store: QuotaStore
    let network: NetworkObserver
    let observeNetwork: @Sendable () -> NetworkObservation
    var lastPrunedDay: String?
    var retentionTask: Task<Void, Never>?
    var retentionError: String?
    var monitoring: MonitoringStatus = .unavailable
    var sampledAt: Date?
    var sampledAtByCategory: [TrafficCategory: Date] = [:]
    var interfaceSampledCategory: TrafficCategory?
    var samplingStartedAt: Date?
    var monitoringMessage = "采集尚未启动。"
    var coverageMessage = "分别累计服务运行期间的热点／高成本与普通网络观测增量；不代表完整账单。"
    var accumulator = TrafficAccumulator()
    var sampler: NettopSampler?
    var samplingTask: Task<Void, Never>?
    var samplingGeneration: UInt64 = 0
    var gaps = 0
    var interfaceAlertWindow = TrafficAlertWindow()
    var applicationAlertWindow = TrafficAlertWindow()
    var trafficAlertWrites = TrafficAlertWriteBuffer()
    var trafficAlertEpoch: UInt64 = 0
    var interfaceAlertMessage = "接口短时窗口待建立。"
    var applicationAlertMessage = "应用短时窗口待建立。"
    let interfaceReader: any InterfaceCounterReading
    let samplingTime: @Sendable () -> UInt64
    var interfaceAccumulator = InterfaceTrafficAccumulator()
    var interfaceTask: Task<Void, Never>?
    var interfaceSampledAt: Date?
    var interfaceMessage = "接口总量尚未就绪；旧应用合计不作为接口历史。"
    let mihomoController: MihomoControllerClient
    var mihomoTask: Task<Void, Never>?
    var mihomoAccumulator = MihomoProxyAccumulator()
    var mihomoProxy = MihomoProxySnapshot(status: .paused, message: "Mihomo API 观测尚未启动。")

    init(store: QuotaStore,
         interfaceReader: any InterfaceCounterReading = SystemInterfaceTrafficCounter(),
         networkObservation: (@Sendable () -> NetworkObservation)? = nil,
         samplingTime: @escaping @Sendable () -> UInt64 = { SamplingClock.nowNanoseconds },
         mihomoController: MihomoControllerClient = MihomoControllerClient()) {
        self.store = store
        self.interfaceReader = interfaceReader
        self.samplingTime = samplingTime
        self.mihomoController = mihomoController
        let network = NetworkObserver()
        self.network = network
        observeNetwork = networkObservation ?? { network.snapshot() }
    }

    func handle(_ request: AgentRequest) async throws -> AgentReply {
        switch request {
        case .applicationTimeline(let query):
            try await pruneIfNeeded(day: try LocalDay.key(for: Date(), in: .current))
            let rows = try await store.applicationTimelineRows(query)
            guard query.day == (try LocalDay.key(for: Date(), in: .current)) else {
                throw PlatformError.unavailable("应用分时查询日期已变化，请刷新。")
            }
            let clash = try mihomoAccumulator.timelineRows(query)
            return .applicationTimeline(try ApplicationTimelineGrouping.make(query: query, rows: rows + clash,
                clashNotice: mihomoAccumulator.timelineNotice(for: query.category)))
        case .snapshot:
            return .snapshot(try await snapshot())
        case .trafficAlertHistory(let day, let offset):
            guard day == (try LocalDay.key(for: Date(), in: .current)), (0...256).contains(offset) else {
                throw TrafficAlertError.invalidEvent
            }
            return .trafficAlertHistory(try await store.trafficAlertEvents(day: day, limit: 32, offset: offset))
        case .categoryTrafficAlertHistory(let category, let day, let offset):
            guard day == (try LocalDay.key(for: Date(), in: .current)), (0...256).contains(offset) else {
                throw TrafficAlertError.invalidEvent
            }
            return .trafficAlertHistory(try await store.trafficAlertEvents(day: day, limit: 32, offset: offset, category: category))
        case .saveCategoryTrafficAlertPolicy(let category, let policy):
            try await store.saveTrafficAlertPolicy(policy, category: category)
            try trafficAlertPolicyChanged(policy, category: category)
            return .acknowledged
        case .saveCategoryRule(let category, let appKey, let rule):
            try await store.saveRule(appKey: appKey, rule: rule, category: category)
            return .acknowledged
        case .saveTrafficAlertPolicy(let policy):
            try await store.saveTrafficAlertPolicy(policy)
            try trafficAlertPolicyChanged(policy, category: .metered)
            return .acknowledged
        case .acknowledgeTrafficAlert(let id):
            let day = try LocalDay.key(for: Date(), in: .current)
            try await store.acknowledgeTrafficAlert(id: id, day: day)
            return .acknowledged
        case .saveRule(let appKey, let rule):
            // ACK confirms a notification configuration transaction, not traffic control.
            try await store.saveRule(appKey: appKey, rule: rule)
            return .acknowledged
        case .setHotspotOverride(let marked):
            try network.markCurrentPath(marked)
            resetTrafficAlertWindows()
            accumulator.reset()
            interfaceAccumulator.reset()
            interfaceSampledAt = nil
            interfaceMessage = "计量范围已变化，接口总量将从下一次基线开始累计。"
            return .acknowledged
        case .startMonitoring:
            await startMonitoring()
            return .acknowledged
        case .acknowledgeNotification(let key):
            let day = try LocalDay.key(for: Date(), in: .current)
            guard key.identity.day == day else {
                throw PlatformError.unavailable("通知日期已变化，旧提醒不再确认。")
            }
            let rows = try await store.snapshot(day: day, category: key.category)
            guard let row = rows.first(where: { $0.identity.key == key.identity.appKey }),
                  let rule = row.rule, rule.version == key.identity.ruleVersion else {
                throw PlatformError.unavailable("提醒规则已变化，请重新读取状态。")
            }
            let decision = try QuotaEvaluator.evaluate(rule: rule, usage: row.usage,
                network: key.category == .metered ? .hotspot : .ordinary)
            let eligible = key.kind == .blocked ? decision.status == .blocked
                : decision.status == .warning || decision.status == .blocked
            guard eligible else { throw PlatformError.unavailable("尚未达到对应提醒阈值。") }
            _ = try await store.claimNotification(appKey: key.identity.appKey, day: day,
                                                  kind: key.kind, ruleVersion: key.identity.ruleVersion, category: key.category)
            return .acknowledged
        case .stopProtection:
            await stopMonitoring()
            return .acknowledged
        }
    }

}
