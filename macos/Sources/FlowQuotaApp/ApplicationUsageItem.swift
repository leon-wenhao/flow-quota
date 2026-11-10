import FlowQuotaCore

/// Display rows use the reconciled physical-meter breakdown when available.
/// Application rules and alerts continue to use the raw canonical ledger.
enum ApplicationUsageItem: Identifiable {
    case application(ApplicationSnapshot, Int64?)
    case clash(MihomoProxySource, Int64?)
    case unidentified(ReconciledTrafficSource)

    var id: String {
        switch self {
        case .application(let app, _): "application:" + app.id
        case .clash(let source, _): "clash:" + source.id
        case .unidentified(let source): "unidentified:" + source.id
        }
    }

    var bytes: Int64? {
        switch self {
        case .application(_, let bytes), .clash(_, let bytes): bytes
        case .unidentified(let source): source.totalBytes
        }
    }
}

extension AppState {
    var categoryMihomoProxy: MihomoProxySnapshot? {
        let proxy = categorySnapshot?.mihomoProxy ?? snapshot?.mihomoProxy
        guard proxy?.day == Self.localDay(), proxy?.category == selectedTrafficCategory else { return nil }
        return proxy
    }

    /// Reconciled rows sum to the measured interface parent for accepted minutes.
    /// The raw process ledger remains available through measurement details.
    var applicationUsageItems: [ApplicationUsageItem] {
        if let sources = categorySnapshot?.reconciledTraffic?.sources {
            let appsByKey = Dictionary(uniqueKeysWithValues: applications.map { ($0.identity.key, $0) })
            return sources.compactMap { source in
                switch source.kind {
                case .application:
                    guard let appKey = source.appKey, let app = appsByKey[appKey] else { return nil }
                    return .application(app, source.totalBytes)
                case .clash:
                    let id = source.id.hasPrefix("clash:") ? String(source.id.dropFirst("clash:".count)) : source.id
                    return .clash(MihomoProxySource(id: id, displayName: source.name, connectionCount: 0,
                        uploadedBytes: source.uploadedBytes, downloadedBytes: source.downloadedBytes), source.totalBytes)
                case .unidentified:
                    return .unidentified(source)
                }
            }
        }
        return fallbackApplicationUsageItems
    }

    private var fallbackApplicationUsageItems: [ApplicationUsageItem] {
        let parents = applications.filter { ClashUsageBreakdown.isProxy($0.identity) }
        var items = applications.filter { !ClashUsageBreakdown.isProxy($0.identity) }
            .map { ApplicationUsageItem.application($0, knownUsage($0)) }
        if let sources = categorySnapshot?.clashBreakdown?.sources {
            items += sources.map { .clash($0.proxySource, usageAvailable ? $0.proxySource.totalBytes : nil) }
        } else {
            items += parents.map { app in
                let source = ClashUsageBreakdown.unknown(upload: app.usage.uploadedBytes, download: app.usage.downloadedBytes)
                return .clash(source.proxySource, knownUsage(app))
            }
        }
        return items.sorted { ($0.bytes ?? -1) == ($1.bytes ?? -1) ? $0.id < $1.id : ($0.bytes ?? -1) > ($1.bytes ?? -1) }
    }

    var topUsageItems: [ApplicationUsageItem] {
        Array(applicationUsageItems.filter { ($0.bytes ?? 0) > 0 }.prefix(3))
    }

    var trafficBreakdownError: String? { categorySnapshot?.reconciledTrafficError }
    var trafficBreakdownNotice: String? { categorySnapshot?.reconciledTraffic?.notice }

    var clashSourceFailure: String? {
        if let failure = categorySnapshot?.clashSourceError { return failure }
        guard let proxy = categoryMihomoProxy else { return nil }
        if proxy.status == .stale || proxy.status == .unavailable || proxy.message.contains("上限") {
            return proxy.message
        }
        return nil
    }
}
