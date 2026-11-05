import Foundation
import Testing
@testable import FlowQuotaApp

@Test func refreshPreferenceSurvivesReloadAndRejectsUnsupportedValues() throws {
    let suite = "FlowQuotaTests.refresh.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(UsageRefreshPreference.seconds(in: defaults) == 5)
    defaults.set(2, forKey: UsageRefreshPreference.key)
    let reloaded = try #require(UserDefaults(suiteName: suite))
    #expect(UsageRefreshPreference.seconds(in: reloaded) == 2)
    for invalid in [0, -1, 6, Int.max] {
        defaults.set(invalid, forKey: UsageRefreshPreference.key)
        #expect(UsageRefreshPreference.seconds(in: defaults) == 5)
    }
    defaults.set("invalid", forKey: UsageRefreshPreference.key)
    #expect(UsageRefreshPreference.seconds(in: defaults) == 5)
}

@MainActor @Test func backgroundLoopReadsChangedPreferenceWithoutRestarting() async throws {
    let suite = "FlowQuotaTests.monitor.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(1, forKey: UsageRefreshPreference.key)
    let client = FakeAgentClient()
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    let monitor = AppMonitor(state: state, defaults: defaults)
    monitor.start()
    defer { monitor.stop() }
    let secondDeadline = ContinuousClock.now + .seconds(3)
    while client.fetchCount < 2 && ContinuousClock.now < secondDeadline { await Task.yield() }
    try #require(client.fetchCount == 2)
    // Let the second request finish and enter its existing one-second wait.
    try await Task.sleep(for: .milliseconds(150))
    defaults.set(5, forKey: UsageRefreshPreference.key)
    let thirdDeadline = ContinuousClock.now + .seconds(2)
    while client.fetchCount < 3 && ContinuousClock.now < thirdDeadline { await Task.yield() }
    try #require(client.fetchCount == 3)
    // The third request must pick up five seconds, rather than the initial one.
    try await Task.sleep(for: .milliseconds(1_200))
    #expect(client.fetchCount == 3)
    monitor.stop()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(50))
    #expect(client.fetchCount == 3)
}
