import Foundation
import FlowQuotaCore
import FlowQuotaPlatform

extension AgentRuntime {
    func snapshot() async throws -> AgentSnapshot {
        let now = Date()
        let path = observeNetwork()
        let day = try LocalDay.key(for: now, in: .current)
        try await pruneIfNeeded(day: day)
        var categories: [TrafficCategorySnapshot] = []
        var notices: [ReminderNotification] = []
        var pending: [TrafficAlertEvent] = []
        let currentSample = currentDaySample(sampledAt, day: day)
        for category in TrafficCategory.allCases {
            let data = try await categorySnapshot(category, day: day, path: path, now: now)
            categories.append(data)
            let policy = data.trafficAlertPolicy
            if monitoring != .paused {
                pending += data.trafficAlertEvents.filter {
                    $0.scheduledAt == nil && $0.policyVersion == policy.version
                        && policy.threshold(for: $0.kind) == $0.thresholdBytes
                        && ($0.kind == .dailyInterface || $0.windowSeconds == policy.windowSeconds)
                }
            }
            // A path change must not suppress an earned notification from the other
            // ledger. Versions, durable receipts and OS IDs are category-scoped.
            if monitoring == .collecting, currentSample != nil {
                let delivered = try await store.deliveredNotifications(day: day, category: category)
                for row in data.applications {
                    guard let rule = row.rule, let limit = rule.limitBytes else { continue }
                    let identity = try QuotaIdentity(appKey: row.identity.key, day: day, ruleVersion: rule.version)
                    let transition = try QuotaTransitions.evaluate(identity: identity, rule: rule,
                        usage: row.usage, network: category == .metered ? .hotspot : .ordinary,
                        delivered: delivered, category: category)
                    if let key = transition.notification {
                        notices.append(ReminderNotification(key: key, appName: row.identity.name,
                            usedBytes: row.usage.totalBytes, limitBytes: limit))
                    }
                }
            }
        }
        let metered = categories[0]
        let stale = (sampledAt ?? samplingStartedAt).map { now.timeIntervalSince($0) > 12 } ?? false
        let active = monitoring == .collecting || monitoring == .unavailable
        let status: MonitoringStatus = active && stale ? .failed : monitoring
        pending.sort { $0.occurredAt < $1.occurredAt }
        return AgentSnapshot(generatedAt: now, network: path.state, readiness: .notInstalled,
            applications: metered.applications,
            message: (stale && active ? "采样超时，当前用量不再更新。" : monitoringMessage) + " " + path.message,
            monitoring: status,
            samplingEnabled: monitoring != .paused && (samplingTask != nil || interfaceTask != nil),
            sampledAt: currentSample, notifications: status == .collecting ? notices : [], coverageMessage: coverageMessage + (retentionError.map { " 数据清理异常：" + $0 } ?? ""),
            interfaceUsage: metered.interfaceUsage, interfaceSampledAt: metered.interfaceSampledAt,
            interfaceMessage: interfaceStatusMessage(at: now), trafficAlertPolicy: metered.trafficAlertPolicy,
            trafficAlertEvents: Array(metered.trafficAlertEvents.prefix(64)), pendingTrafficAlerts: Array(pending.prefix(16)),
            trafficAlertMessage: interfaceAlertMessage + " " + applicationAlertMessage + " " + alertAttributionMessage, trafficCategories: categories, mihomoProxy: mihomoProxy)
    }

    private func categorySnapshot(_ category: TrafficCategory, day: String,
                                  path: NetworkObservation, now: Date) async throws -> TrafficCategorySnapshot {
        let apps = try await store.snapshot(day: day, category: category)
        let observed = try await store.hasApplicationUsage(day: day, category: category)
        let policy = try await store.trafficAlertPolicy(category: category)
        let events = try await store.trafficAlertEvents(day: day, category: category).map { $0.summaryOnly() }
        let usage = try await store.interfaceUsage(day: day, category: category)
        let minutes = try await store.interfaceUsageMinutes(day: day, category: category)
        let isActiveCategory = path.state.trafficCategory == category
        let interfaceDate = isActiveCategory && interfaceSampledCategory == category
            ? currentDaySample(interfaceSampledAt, day: day) : nil
        return TrafficCategorySnapshot(category: category, applications: apps, applicationsAvailable: observed,
            sampledAt: currentDaySample(sampledAtByCategory[category], day: day), interfaceUsage: usage,
            interfaceSampledAt: interfaceDate,
            interfaceMessage: isActiveCategory ? interfaceStatusMessage(at: now)
                : "当前连接不属于\(category.title)；仅显示该类今日已观测累计，未观测区间未知。",
            trafficAlertPolicy: policy, trafficAlertEvents: events, interfaceUsageMinutes: minutes,
            mihomoProxy: mihomoAccumulator.snapshot(category: category, day: day,
                status: mihomoProxy.status, message: mihomoProxy.message))
    }

    private func currentDaySample(_ date: Date?, day: String) -> Date? {
        date.flatMap { (try? LocalDay.key(for: $0, in: .current)) == day ? $0 : nil }
    }
}
