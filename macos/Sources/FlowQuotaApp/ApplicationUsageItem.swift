import FlowQuotaCore

/// One list, two explicit measurement scopes. API rows never become editable
/// quota identities or get added to the durable nettop ledger.
enum ApplicationUsageItem: Identifiable {
    case application(ApplicationSnapshot, Int64?)
    case clash(MihomoProxySource, Int64?)

    var id: String {
        switch self {
        case .application(let app, _): "application:" + app.id
        case .clash(let source, _): "clash:" + source.id
        }
    }

    var bytes: Int64? {
        switch self {
        case .application(_, let bytes), .clash(_, let bytes): bytes
        }
    }
}

extension AppState {
    var categoryMihomoProxy: MihomoProxySnapshot? {
        let proxy = categorySnapshot?.mihomoProxy ?? snapshot?.mihomoProxy
        guard proxy?.day == Self.localDay(), proxy?.category == selectedTrafficCategory else { return nil }
        return proxy
    }

    var applicationUsageItems: [ApplicationUsageItem] {
        let apps = applications.map { ApplicationUsageItem.application($0, knownUsage($0)) }
        return apps.sorted {
            let left = $0.bytes ?? -1
            let right = $1.bytes ?? -1
            return left == right ? $0.id < $1.id : left > right
        }
    }

    /// Auxiliary children, kept separate from process totals and the top-three ranking.
    var clashUsageItems: [ApplicationUsageItem] {
        let sources = (categoryMihomoProxy?.sources ?? []).map {
            ApplicationUsageItem.clash($0, connected && snapshotIsCurrent ? $0.totalBytes : nil)
        }
        return sources.sorted {
            let left = $0.bytes ?? -1
            let right = $1.bytes ?? -1
            return left == right ? $0.id < $1.id : left > right
        }
    }

    /// Same category and ranking as the complete process list. Unknown and zero values
    /// never displace a source with actual observed use in the quick overview.
    var topUsageItems: [ApplicationUsageItem] {
        Array(applicationUsageItems.filter { ($0.bytes ?? 0) > 0 }.prefix(3))
    }

    var clashAttributionNotice: String {
        guard connected, snapshotIsCurrent else { return "Clash 来源识别状态未知；等待本地服务。" }
        guard let proxy = categoryMihomoProxy else { return "Clash 来源将在有效 API 观测后显示。" }
        switch proxy.status {
        case .paused: return "Flow Quota 已暂停来源采集；Clash 本身的状态不受影响。"
        case .stale, .unavailable: return proxy.message
        case .observing: return proxy.message
        }
    }
}
