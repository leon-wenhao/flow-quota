import Foundation

public enum QuotaBudgetError: Error, Equatable, Sendable {
    case negativeUsage, invalidRequest, invalidReservationBound, tooManyReservations
    case unknownReservation, invalidConsumption, staleRuleVersion, conflictingRuleVersion
}

/// Opaque single-use grant. Only its issuing ledger can settle it; identity never changes when
/// a rule changes or the connection crosses midnight. A token is not a durable/network lease.
public struct BudgetReservation: Equatable, Sendable {
    public let id: UUID
    public let identity: QuotaIdentity
    public let grantedBytes: Int64
}

public struct QuotaBudgetSnapshot: Equatable, Sendable {
    public let identity: QuotaIdentity
    public let rule: QuotaRule
    public let usedBytes: Int64
    public let reservedBytes: Int64
    /// Unlimited rules are still bounded by representable Int64 counters.
    public let availableBytes: Int64
    public let pendingReservations: Int
}

/// In-memory arithmetic model for ONE stable app and local day, shared by all its connections.
/// No networking or persistence is implemented. The service must restore a trusted used/high-water
/// value before construction, persist grants BEFORE real consumption, and keep unresolved grants
/// charged after crashes. Do not use an empty instance as a restart recovery strategy.
public actor QuotaBudgetLedger {
    private var identity: QuotaIdentity
    private let maximumPendingReservations: Int
    private var rule: QuotaRule
    private var usedBytes: Int64
    private var reservedBytes: Int64 = 0
    private var reservations: [UUID: BudgetReservation] = [:]

    /// `usedBytes` is a trusted nonnegative total for this app/day, not a per-connection total.
    /// Capacity bounds memory; pending reservations never expire automatically or free budget.
    public init(appKey: String, day: String, rule: QuotaRule, usedBytes: Int64,
                maximumPendingReservations: Int = 1_024) throws {
        let identity = try QuotaIdentity(appKey: appKey, day: day, ruleVersion: rule.version)
        guard usedBytes >= 0 else { throw QuotaBudgetError.negativeUsage }
        guard maximumPendingReservations > 0 else { throw QuotaBudgetError.invalidReservationBound }
        self.identity = identity
        self.rule = rule
        self.usedBytes = usedBytes
        self.maximumPendingReservations = maximumPendingReservations
    }

    /// Atomically reserves up to `bytes`, returning a partial final grant or nil at exhaustion.
    /// Caller must establish hotspot scope, current date and readiness before requesting a grant.
    /// Synchronous actor methods deliberately contain no await/reentrancy between check and debit.
    public func reserve(bytes: Int64) throws -> BudgetReservation? {
        guard bytes > 0 else { throw QuotaBudgetError.invalidRequest }
        let available = availableBytes
        guard available > 0 else { return nil }
        guard reservations.count < maximumPendingReservations else { throw QuotaBudgetError.tooManyReservations }
        let token = BudgetReservation(id: UUID(), identity: identity, grantedBytes: min(bytes, available))
        reservations[token.id] = token
        reservedBytes += token.grantedBytes
        return token
    }

    /// Final settlement: consumed is a cumulative actual total in 0...grant, NOT a delta.
    /// Only the unused portion is released. Invalid/duplicate/foreign reports throw without
    /// mutation. Old-version tokens settle only against their original app/day ledger.
    @discardableResult
    public func reconcile(_ reservation: BudgetReservation, consumedBytes: Int64) throws -> QuotaBudgetSnapshot {
        guard reservations[reservation.id] == reservation else { throw QuotaBudgetError.unknownReservation }
        guard (0...reservation.grantedBytes).contains(consumedBytes) else {
            throw QuotaBudgetError.invalidConsumption
        }
        reservations.removeValue(forKey: reservation.id)
        reservedBytes -= reservation.grantedBytes
        // used + held never exceeds Int64.max, including for unlimited rules.
        usedBytes += consumedBytes
        return snapshot()
    }

    /// Release only when the caller has proven no bytes from this grant were consumed/in flight.
    /// Network disconnect/cancellation alone is not that proof; reconcile actuals or forfeit.
    @discardableResult
    public func release(_ reservation: BudgetReservation) throws -> QuotaBudgetSnapshot {
        try reconcile(reservation, consumedBytes: 0)
    }

    /// Conservatively charges the entire unresolved grant; never replenishes uncertain budget.
    @discardableResult
    public func forfeit(_ reservation: BudgetReservation) throws -> QuotaBudgetSnapshot {
        try reconcile(reservation, consumedBytes: reservation.grantedBytes)
    }

    /// Requires increasing revisions (exact duplicate is idempotent). Usage and pending grants
    /// survive changes, including disable/re-enable. Lowering a cap cannot retract prior bytes:
    /// the eventual provider must stop/revalidate old grants before allowing further data. Held
    /// old-version grants still reduce new availability until explicitly settled, never erased.
    @discardableResult
    public func updateRule(_ newRule: QuotaRule) throws -> QuotaBudgetSnapshot {
        guard newRule.version >= rule.version else { throw QuotaBudgetError.staleRuleVersion }
        if newRule.version == rule.version {
            guard newRule == rule else { throw QuotaBudgetError.conflictingRuleVersion }
        } else {
            identity = try QuotaIdentity(appKey: identity.appKey, day: identity.day, ruleVersion: newRule.version)
            rule = newRule
        }
        return snapshot()
    }

    /// False after a rule update or settlement. This does not validate current day/network;
    /// a provider must also recompute those for each chunk, not only when a connection opens.
    public func isCurrent(_ reservation: BudgetReservation) -> Bool {
        reservations[reservation.id] == reservation && reservation.identity == identity
    }

    public func snapshot() -> QuotaBudgetSnapshot {
        QuotaBudgetSnapshot(identity: identity, rule: rule, usedBytes: usedBytes,
                            reservedBytes: reservedBytes, availableBytes: availableBytes,
                            pendingReservations: reservations.count)
    }

    private var availableBytes: Int64 {
        let ceiling = rule.limitBytes ?? .max
        guard usedBytes < ceiling, reservedBytes < ceiling - usedBytes else { return 0 }
        return ceiling - usedBytes - reservedBytes
    }
}
