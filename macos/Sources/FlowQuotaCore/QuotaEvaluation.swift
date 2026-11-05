import Foundation

public enum QuotaEvaluationError: Error, Equatable, Sendable {
    case negativeUsage, identityMismatch, ruleVersionMismatch
}

/// Domain decisions only. These states never certify that a filter or meter is installed/ready.
public enum QuotaStatus: String, Codable, Sendable {
    case ordinaryNetwork, unknownNetwork, usageUnavailable, unlimited, withinLimit, warning, blocked
}

public struct QuotaEvaluation: Equatable, Sendable {
    public let status: QuotaStatus
    /// True for automatic high-cost paths or manual hotspot marks; ordinary/unknown paths do not count.
    public let countsTraffic: Bool
    /// Nil for unlimited, unavailable or inapplicable evaluation. Never negative.
    public let remainingBytes: Int64?
    public let warningThresholdBytes: Int64?
}

public enum QuotaEvaluator {
    /// Upload + download are metered-scope counters for the selected app/day, never all-network
    /// traffic. Nil means unavailable, not zero. Negative counters throw; total overflow saturates.
    public static func evaluate(rule: QuotaRule?, usage: DailyUsage?,
                                network: NetworkState) throws -> QuotaEvaluation {
        if let usage, usage.uploadedBytes < 0 || usage.downloadedBytes < 0 {
            throw QuotaEvaluationError.negativeUsage
        }
        switch network {
        case .ordinary: return result(.ordinaryNetwork, counts: false)
        case .unknown: return result(.unknownNetwork, counts: false)
        case .hotspot, .expensive: break
        }
        guard let usage else { return result(.usageUnavailable, counts: true) }
        guard let rule, let limit = rule.limitBytes else { return result(.unlimited, counts: true) }
        let used = usage.totalBytes
        // ceil(limit * percent / 100), avoiding an overflowing intermediate product.
        let remainderProduct = (limit % 100) * Int64(rule.warningPercent)
        let threshold = (limit / 100) * Int64(rule.warningPercent) + (remainderProduct + 99) / 100
        let status: QuotaStatus = used >= limit ? .blocked : (used >= threshold ? .warning : .withinLimit)
        return QuotaEvaluation(status: status, countsTraffic: true,
                               remainingBytes: used >= limit ? 0 : limit - used,
                               warningThresholdBytes: threshold)
    }

    private static func result(_ status: QuotaStatus, counts: Bool) -> QuotaEvaluation {
        QuotaEvaluation(status: status, countsTraffic: counts,
                        remainingBytes: nil, warningThresholdBytes: nil)
    }
}

public enum QuotaNotificationKind: String, Codable, Sendable { case warning, blocked }

public struct QuotaNotificationKey: Codable, Hashable, Sendable {
    public let identity: QuotaIdentity
    public let kind: QuotaNotificationKind

    public init(identity: QuotaIdentity, kind: QuotaNotificationKind) {
        self.identity = identity
        self.kind = kind
    }
}

public struct QuotaTransition: Equatable, Sendable {
    public let evaluation: QuotaEvaluation
    /// Proposal only: the service must persist/acknowledge notification state separately.
    public let notification: QuotaNotificationKey?
}

public enum QuotaTransitions {
    /// Derives transitions from current counters and durable dedup keys, so restart/reconnect
    /// need not replay a previous UI state. A direct jump to blocked emits only blocked;
    /// a recorded block suppresses a later warning for the same identity. New rule versions
    /// may notify again. Does not send notifications or mutate the supplied keys.
    public static func evaluate(identity: QuotaIdentity, rule: QuotaRule, usage: DailyUsage?,
                                network: NetworkState,
                                delivered: Set<QuotaNotificationKey> = []) throws -> QuotaTransition {
        guard identity.ruleVersion == rule.version else { throw QuotaEvaluationError.ruleVersionMismatch }
        if let usage, usage.appKey != identity.appKey || usage.day != identity.day {
            throw QuotaEvaluationError.identityMismatch
        }
        let evaluation = try QuotaEvaluator.evaluate(rule: rule, usage: usage, network: network)
        let block = QuotaNotificationKey(identity: identity, kind: .blocked)
        var notification: QuotaNotificationKey?
        if evaluation.status == .blocked, !delivered.contains(block) {
            notification = block
        } else if evaluation.status == .warning, !delivered.contains(block) {
            let warning = QuotaNotificationKey(identity: identity, kind: .warning)
            if !delivered.contains(warning) { notification = warning }
        }
        return QuotaTransition(evaluation: evaluation, notification: notification)
    }
}
