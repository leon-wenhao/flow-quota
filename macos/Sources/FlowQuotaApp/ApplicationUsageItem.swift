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

    /// All daily/menu surfaces share the service's minute-validated decomposition.
    /// Raw parent records remain available to its rule editor in measurement details.
    var applicationUsageItems: [ApplicationUsageItem] {
        let parents = applications.filter { ClashUsageBreakdown.isProxy($0.identity) }
        var items = applications.filter { !ClashUsageBreakdown.isProxy($0.identity) }
            .map { ApplicationUsageItem.application($0, knownUsage($0)) }
        if let sources = categorySnapshot?.clashBreakdown?.sources {
            items += sources.map { .clash($0.proxySource, usageAvailable ? $0.proxySource.totalBytes : nil) }
        } else {
            // Older/missing source evidence never removes the parent's bytes.
            items += parents.map { app in
                let source = ClashUsageBreakdown.unknown(upload: app.usage.uploadedBytes, download: app.usage.downloadedBytes)
                return .clash(source.proxySource, knownUsage(app))
            }
        }
        return items.sorted {
            let left = $0.bytes ?? -1
            let right = $1.bytes ?? -1
            return left == right ? $0.id < $1.id : left > right
        }
    }

    var topUsageItems: [ApplicationUsageItem] {
        Array(applicationUsageItems.filter { ($0.bytes ?? 0) > 0 }.prefix(3))
    }

    var clashSourceFailure: String? {
        if let failure = categorySnapshot?.clashSourceError { return failure }
        guard let proxy = categoryMihomoProxy else { return nil }
        if proxy.status == .stale || proxy.status == .unavailable || proxy.message.contains("上限") {
            return proxy.message
        }
        return nil
    }

}
