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
    var monitoring: MonitoringStatus = .unavailable
    var sampledAt: Date?
    var samplingStartedAt: Date?
    var monitoringMessage = "采集尚未启动。"
    var coverageMessage = "仅累计服务运行期间的高成本网络或手动热点观测增量；不代表完整账单。"
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

    init(store: QuotaStore,
         interfaceReader: any InterfaceCounterReading = SystemInterfaceTrafficCounter(),
         networkObservation: (@Sendable () -> NetworkObservation)? = nil,
         samplingTime: @escaping @Sendable () -> UInt64 = { SamplingClock.nowNanoseconds }) {
        self.store = store
        self.interfaceReader = interfaceReader
        self.samplingTime = samplingTime
        let network = NetworkObserver()
        self.network = network
        observeNetwork = networkObservation ?? { network.snapshot() }
    }

    func handle(_ request: AgentRequest) async throws -> AgentReply {
        switch request {
        case .snapshot:
            return .snapshot(try await snapshot())
        case .trafficAlertHistory(let day, let offset):
            guard day == (try LocalDay.key(for: Date(), in: .current)), (0...256).contains(offset) else {
                throw TrafficAlertError.invalidEvent
            }
            return .trafficAlertHistory(try await store.trafficAlertEvents(day: day, limit: 32, offset: offset))
        case .saveTrafficAlertPolicy(let policy):
            try await store.saveTrafficAlertPolicy(policy)
            resetTrafficAlertWindows()
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
            let rows = try await store.snapshot(day: day)
            guard let row = rows.first(where: { $0.identity.key == key.identity.appKey }),
                  let rule = row.rule, rule.version == key.identity.ruleVersion else {
                throw PlatformError.unavailable("提醒规则已变化，请重新读取状态。")
            }
            let decision = try QuotaEvaluator.evaluate(rule: rule, usage: row.usage, network: .hotspot)
            let eligible = key.kind == .blocked ? decision.status == .blocked
                : decision.status == .warning || decision.status == .blocked
            guard eligible else { throw PlatformError.unavailable("尚未达到对应提醒阈值。") }
            _ = try await store.claimNotification(appKey: key.identity.appKey, day: day,
                                                  kind: key.kind, ruleVersion: key.identity.ruleVersion)
            return .acknowledged
        case .stopProtection:
            await stopMonitoring()
            return .acknowledged
        }
    }

    func snapshot() async throws -> AgentSnapshot {
        let now = Date()
        let path = observeNetwork()
        let day = try LocalDay.key(for: now, in: .current)
        if day != lastPrunedDay {
            try await store.prunePreviousDays()
            lastPrunedDay = day
        }
        let rows = try await store.snapshot(day: day)
        let alertPolicy = try await store.trafficAlertPolicy()
        let alertEvents = try await store.trafficAlertEvents(day: day)
        let alertPending = monitoring == .paused ? [] : alertEvents.filter {
            $0.scheduledAt == nil && $0.policyVersion == alertPolicy.version
                && alertPolicy.threshold(for: $0.kind) != nil
        }
        let delivered = try await store.deliveredNotifications(day: day)
        var notices: [ReminderNotification] = []
        // A new day has no known observation until its own baseline is captured.
        let currentSample = sampledAt.flatMap { (try? LocalDay.key(for: $0, in: .current)) == day ? $0 : nil }
        // The stored counters cover automatic high-cost paths and manual hotspots.
        // A later path switch must not suppress
        // an already-earned reminder that the UI has not yet scheduled.
        if monitoring == .collecting, currentSample != nil {
            for row in rows {
                guard let rule = row.rule, let limit = rule.limitBytes else { continue }
                let identity = try QuotaIdentity(appKey: row.identity.key, day: day, ruleVersion: rule.version)
                let transition = try QuotaTransitions.evaluate(identity: identity, rule: rule,
                    usage: row.usage, network: .hotspot, delivered: delivered)
                if let key = transition.notification {
                    notices.append(ReminderNotification(key: key, appName: row.identity.name,
                                                        usedBytes: row.usage.totalBytes, limitBytes: limit))
                }
            }
        }
        let stale = (sampledAt ?? samplingStartedAt).map { now.timeIntervalSince($0) > 12 } ?? false
        let active = monitoring == .collecting || monitoring == .unavailable
        let status: MonitoringStatus = active && stale ? .failed : monitoring
        return AgentSnapshot(generatedAt: now, network: path.state, readiness: .notInstalled,
            applications: rows, message: (stale && active ? "采样超时，当前用量不再更新。" : monitoringMessage)
                + " " + path.message,
            monitoring: status,
            samplingEnabled: monitoring != .paused && (samplingTask != nil || interfaceTask != nil),
            sampledAt: currentSample, notifications: status == .collecting ? notices : [],
            coverageMessage: coverageMessage,
            interfaceUsage: try await store.interfaceUsage(day: day),
            interfaceSampledAt: interfaceSampledAt.flatMap {
                (try? LocalDay.key(for: $0, in: .current)) == day ? $0 : nil
            }, interfaceMessage: interfaceStatusMessage(at: now), trafficAlertPolicy: alertPolicy,
            trafficAlertEvents: Array(alertEvents.prefix(64)), pendingTrafficAlerts: Array(alertPending.prefix(16)),
            trafficAlertMessage: interfaceAlertMessage + " " + applicationAlertMessage)
    }
}
