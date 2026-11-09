import Foundation
import Observation

/// A local schedule for Sparkle's informational probes, independent of traffic
/// classification and sampling. No package download or installation is scheduled.
@MainActor @Observable
final class AutomaticUpdateChecks {
    static let enabledKey = "automaticUpdateChecksEnabled"
    private static let attemptKey = "lastUpdateCheckAttempt"
    private static let successKey = "lastSuccessfulUpdateCheck"
    static let startupDelay: TimeInterval = 30
    static let successInterval: TimeInterval = 24 * 60 * 60
    static let retryInterval: TimeInterval = 60 * 60

    private(set) var enabled: Bool
    private(set) var lastAttempt: Date?
    private(set) var lastSuccess: Date?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let startedAt: Date

    init(defaults: UserDefaults = .standard, startedAt: Date = Date()) {
        self.defaults = defaults
        self.startedAt = startedAt
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        lastAttempt = defaults.object(forKey: Self.attemptKey) as? Date
        lastSuccess = defaults.object(forKey: Self.successKey) as? Date
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func isDue(at now: Date) -> Bool {
        guard enabled else { return false }
        // A rolled-back system clock must not defer checking until a future date.
        guard now < startedAt || now.timeIntervalSince(startedAt) >= Self.startupDelay else { return false }
        if let lastSuccess, lastSuccess <= now,
           now.timeIntervalSince(lastSuccess) < Self.successInterval { return false }
        if let lastAttempt, lastAttempt <= now,
           now.timeIntervalSince(lastAttempt) < Self.retryInterval { return false }
        return true
    }

    /// Reserve the attempt before calling Sparkle, so repeated poll/wake events
    /// cannot start another probe while the framework is beginning its session.
    @discardableResult
    func checkIfDue(at now: Date, ready: Bool, probe: () -> Void) -> Bool {
        guard ready, isDue(at: now) else { return false }
        recordAttempt(at: now)
        probe()
        return true
    }

    func recordAttempt(at now: Date) {
        lastAttempt = now
        defaults.set(now, forKey: Self.attemptKey)
    }

    func recordSuccess(at now: Date) {
        lastSuccess = now
        defaults.set(now, forKey: Self.successKey)
    }
}
