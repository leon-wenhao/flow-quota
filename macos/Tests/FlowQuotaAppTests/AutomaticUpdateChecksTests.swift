import Foundation
import Sparkle
import Testing
@testable import FlowQuotaApp

@MainActor private func withUpdatePreferences(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "flowquota-auto-update-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

private let updateEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor @Test func automaticChecksDefaultOnAndRememberExplicitOff() {
    withUpdatePreferences { defaults in
        let schedule = AutomaticUpdateChecks(defaults: defaults, startedAt: updateEpoch)
        #expect(schedule.enabled)
        schedule.setEnabled(false)
        let restarted = AutomaticUpdateChecks(defaults: defaults, startedAt: updateEpoch)
        #expect(!restarted.enabled)
        #expect(!restarted.isDue(at: updateEpoch.addingTimeInterval(100_000)))
        restarted.setEnabled(true)
        #expect(AutomaticUpdateChecks(defaults: defaults).enabled)
    }
}

@MainActor @Test func automaticChecksWaitForStartupAndReadinessWithoutConsumingAttempt() {
    withUpdatePreferences { defaults in
        let schedule = AutomaticUpdateChecks(defaults: defaults, startedAt: updateEpoch)
        var calls = 0
        #expect(!schedule.checkIfDue(at: updateEpoch.addingTimeInterval(29), ready: true) { calls += 1 })
        #expect(!schedule.checkIfDue(at: updateEpoch.addingTimeInterval(30), ready: false) { calls += 1 })
        #expect(schedule.lastAttempt == nil)
        #expect(schedule.checkIfDue(at: updateEpoch.addingTimeInterval(30), ready: true) { calls += 1 })
        #expect(!schedule.checkIfDue(at: updateEpoch.addingTimeInterval(35), ready: true) { calls += 1 })
        #expect(calls == 1)
    }
}

@MainActor @Test func failedChecksRetryAfterOneHourAndPersistAcrossRestart() {
    withUpdatePreferences { defaults in
        let first = AutomaticUpdateChecks(defaults: defaults, startedAt: updateEpoch)
        let attempted = updateEpoch.addingTimeInterval(30)
        #expect(first.checkIfDue(at: attempted, ready: true) {})
        let restarted = AutomaticUpdateChecks(defaults: defaults, startedAt: attempted.addingTimeInterval(10))
        #expect(restarted.lastAttempt == attempted)
        #expect(!restarted.isDue(at: attempted.addingTimeInterval(3_599)))
        #expect(restarted.isDue(at: attempted.addingTimeInterval(3_600)))
        #expect(restarted.lastSuccess == nil)
    }
}

@MainActor @Test func successfulChecksIncludingManualChecksDeferAutomaticCheckForADay() {
    withUpdatePreferences { defaults in
        let schedule = AutomaticUpdateChecks(defaults: defaults, startedAt: updateEpoch)
        let success = updateEpoch.addingTimeInterval(30)
        schedule.recordAttempt(at: success)
        schedule.recordSuccess(at: success)
        let restarted = AutomaticUpdateChecks(defaults: defaults, startedAt: success.addingTimeInterval(60))
        #expect(restarted.lastSuccess == success)
        #expect(!restarted.isDue(at: success.addingTimeInterval(86_399)))
        #expect(restarted.isDue(at: success.addingTimeInterval(86_400)))
        // A later manual success starts a fresh daily interval.
        restarted.recordSuccess(at: success.addingTimeInterval(86_400))
        #expect(!restarted.isDue(at: success.addingTimeInterval(86_401)))
    }
}

@MainActor @Test func rolledBackClockDoesNotWaitForFutureTimestamps() {
    withUpdatePreferences { defaults in
        let schedule = AutomaticUpdateChecks(defaults: defaults, startedAt: updateEpoch)
        schedule.recordAttempt(at: updateEpoch.addingTimeInterval(100_000))
        schedule.recordSuccess(at: updateEpoch.addingTimeInterval(100_000))
        let now = updateEpoch.addingTimeInterval(-3_600)
        #expect(schedule.checkIfDue(at: now, ready: true) {})
        #expect(!schedule.isDue(at: now.addingTimeInterval(30)))
        #expect(schedule.isDue(at: now.addingTimeInterval(3_630)))
    }
}

@MainActor @Test func informationalChecksClearFailuresAndNeverStageInstallation() throws {
    try withUpdatePreferences { defaults in
        let updater = AppUpdater(defaults: defaults)
        // The framework is never started: no HTTP, service registration or install.
        let sparkle = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: nil).updater
        try updater.updater(sparkle, mayPerform: .updateInformation)
        #expect(updater.checking)
        updater.updater(sparkle, didFinishUpdateCycleFor: .updateInformation,
                        error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        #expect(!updater.checking)
        #expect(updater.errorMessage != nil)
        #expect(updater.automaticChecks.lastSuccess == nil)
        #expect(!updater.hasStagedUpdate && !updater.hasPendingInstall && !updater.installing)
        try updater.updater(sparkle, mayPerform: .updateInformation)
        #expect(updater.errorMessage == nil)
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
            userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)])
        updater.updaterDidNotFindUpdate(sparkle, error: noUpdate)
        updater.updater(sparkle, didFinishUpdateCycleFor: .updateInformation, error: noUpdate)
        #expect(updater.automaticChecks.lastSuccess != nil)
        #expect(updater.availableVersion == nil)
        #expect(updater.errorMessage == nil)
        #expect(!updater.checking && !updater.recovering && !updater.needsRecovery)
    }
}
