import Foundation
import FlowQuotaCore

extension AppState {
    func saveTrafficAlertPolicy(_ policy: TrafficAlertPolicy, category: TrafficCategory? = nil, acknowledged: @escaping @MainActor () -> Void) {
        let category = category ?? selectedTrafficCategory
        guard canEdit, let current = snapshot?.usage(for: category)?.trafficAlertPolicy ?? (category == .metered ? snapshot?.trafficAlertPolicy : nil),
              current.version < Int64.max, policy.version == current.version + 1 else {
            reportError("预警配置版本已变化，请重新打开设置。")
            return
        }
        perform("正在保存流量预警配置") { state in
            try await state.client.saveTrafficAlertPolicy(policy, category: category)
            state.reportNotice("\(category.title)流量预警配置已持久化；短时窗口重新积累。")
            acknowledged()
            await state.refresh()
        }
    }

    func loadTodayTrafficAlerts() async throws -> [TrafficAlertEvent] {
        guard connected, snapshotIsCurrent, let day = Self.localDay() else { throw TrafficAlertError.invalidEvent }
        let category = selectedTrafficCategory
        var events: [TrafficAlertEvent] = []
        for offset in stride(from: 0, to: 256, by: 32) {
            try Task.checkCancellation()
            let page = try await client.fetchTrafficAlertHistory(day: day, offset: offset, category: category)
            guard connected, snapshotIsCurrent, day == Self.localDay(),
                  selectedTrafficCategory == category,
                  page.count <= 32, page.allSatisfy({ $0.day == day && $0.category == category }) else {
                throw TrafficAlertError.invalidEvent
            }
            for event in page { try event.validate() }
            events.append(contentsOf: page.filter { item in !events.contains(where: { $0.id == item.id }) })
            if page.count < 32 { break }
        }
        return events.sorted {
            $0.occurredAt == $1.occurredAt ? $0.id > $1.id : $0.occurredAt > $1.occurredAt
        }
    }

    func deliverTrafficAlerts(_ next: AgentSnapshot) async {
        let proposals = Array(next.pendingTrafficAlerts.filter { trafficAlertEligible($0) }.prefix(16))
        await trafficAlertDelivery.deliver(proposals) { [weak self] event in
            self?.trafficAlertEligible(event) == true
        }
    }

    /// Authorization and OS scheduling suspend. Revalidate against the newest
    /// snapshot so a pause or policy change cannot send an obsolete proposal.
    private func trafficAlertEligible(_ event: TrafficAlertEvent) -> Bool {
        guard connected, snapshotIsCurrent, !quitRequested,
              snapshot?.monitoring != .paused, event.day == Self.localDay(),
              event.scheduledAt == nil, (try? event.validate()) != nil,
              snapshot?.pendingTrafficAlerts.contains(event) == true,
              let policy = snapshot?.usage(for: event.category)?.trafficAlertPolicy
                ?? (event.category == .metered ? snapshot?.trafficAlertPolicy : nil), (try? policy.validate()) != nil,
              event.policyVersion == policy.version,
              event.thresholdBytes == policy.threshold(for: event.kind) else { return false }
        return event.kind == .dailyInterface || event.windowSeconds == policy.windowSeconds
    }
}
