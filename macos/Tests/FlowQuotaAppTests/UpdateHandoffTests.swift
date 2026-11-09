import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import Testing
import Sparkle
@testable import FlowQuotaApp

@MainActor private final class UpdateTestService: UpdateAgentService {
    let client: FakeAgentClient
    var registered = true
    var events: [String] = []
    var fail: String?
    var unregisterGate: CheckedContinuation<Void, Never>?
    var holdUnregister = false

    init(monitoring: MonitoringStatus = .collecting) { client = FakeAgentClient(monitoring: monitoring) }
    func isRegisteredForUpdate() throws -> Bool { registered }
    func fetchSnapshot() async throws -> AgentSnapshot {
        events.append("snapshot")
        if fail == "snapshot" { throw PlatformError.timeout }
        return try await client.fetchSnapshot()
    }
    func stopProtection() async throws {
        events.append("stop")
        if fail == "stop" { throw PlatformError.timeout }
    }
    func unregisterForUpdate() async throws {
        events.append("unregister")
        if fail == "unregister" { throw PlatformError.timeout }
        if holdUnregister { await withCheckedContinuation { unregisterGate = $0 } }
        registered = false
    }
    func restoreAfterUpdate(resumeSampling: Bool) async throws {
        events.append(resumeSampling ? "restore-active" : "restore-paused")
        if fail == "restore" { throw PlatformError.timeout }
        registered = true
    }
}

@MainActor private func temporaryUpdateStore() -> UpdateResumeStore {
    UpdateResumeStore(defaults: UserDefaults(suiteName: "flowquota-update-test-" + UUID().uuidString)!)
}

@MainActor @Test func installationWaitsForAgentExitAndRestoresOriginalState() async throws {
    let service = UpdateTestService()
    service.holdUnregister = true
    let store = temporaryUpdateStore()
    let handoff = UpdateHandoff(service: service, store: store, build: "26")
    let task = Task { try await handoff.prepare(targetBuild: "27") }
    while service.unregisterGate == nil { await Task.yield() }
    #expect(!handoff.ready)
    #expect(store.hasPendingInstallation)
    #expect(service.events == ["snapshot", "stop", "unregister"])
    service.unregisterGate?.resume()
    try await task.value
    #expect(handoff.ready)
    let newApp = UpdateHandoff(service: service, store: store, build: "27")
    try await newApp.recover()
    #expect(service.events.last == "restore-active")
    #expect(!store.hasPendingInstallation)
}

@MainActor @Test func updatePreservesPausedService() async throws {
    let service = UpdateTestService(monitoring: .paused)
    let store = temporaryUpdateStore()
    let handoff = UpdateHandoff(service: service, store: store, build: "26")
    try await handoff.prepare(targetBuild: "27")
    #expect(try store.read()?.resumeSampling == false)
    try await UpdateHandoff(service: service, store: store, build: "27").recover()
    #expect(service.events.last == "restore-paused")
}

@MainActor @Test func updateDoesNotEnablePreviouslyUnregisteredService() async throws {
    let service = UpdateTestService()
    service.registered = false
    let store = temporaryUpdateStore()
    let handoff = UpdateHandoff(service: service, store: store, build: "26")
    try await handoff.prepare(targetBuild: "27")
    #expect(handoff.ready)
    try await handoff.recover()
    #expect(service.events.isEmpty)
    #expect(!service.registered)
    #expect(!store.hasPendingInstallation)
}

@MainActor @Test(arguments: ["snapshot", "stop", "unregister"])
func failureNeverReleasesInstallationAndRetryKeepsIntent(step: String) async throws {
    let service = UpdateTestService()
    service.fail = step
    let store = temporaryUpdateStore()
    let handoff = UpdateHandoff(service: service, store: store, build: "26")
    await #expect(throws: (any Error).self) { try await handoff.prepare(targetBuild: "27") }
    #expect(!handoff.ready)
    if step == "snapshot" { #expect(!store.hasPendingInstallation) }
    else { #expect(try store.read()?.resumeSampling == true) }
    service.fail = nil
    try await handoff.prepare(targetBuild: "27")
    #expect(handoff.ready)
    try await handoff.recover()
    #expect(service.events.last == "restore-active")
}

@MainActor @Test func failedRecoveryRetainsMarkerAndCanRetry() async throws {
    let service = UpdateTestService()
    let store = temporaryUpdateStore()
    let handoff = UpdateHandoff(service: service, store: store, build: "26")
    try await handoff.prepare(targetBuild: "27")
    service.fail = "restore"
    await #expect(throws: (any Error).self) { try await handoff.recover() }
    #expect(store.hasPendingInstallation)
    #expect(!handoff.ready)
    service.fail = nil
    try await handoff.recover()
    #expect(!store.hasPendingInstallation)
}

@MainActor @Test func staleOrUnexpectedBuildCannotAutomaticallyResumeSampling() async throws {
    let service = UpdateTestService()
    let store = temporaryUpdateStore()
    try store.save(.init(sourceBuild: "26", targetBuild: "27", registered: true,
                         resumeSampling: true, createdAt: Date().addingTimeInterval(-86_401)))
    let handoff = UpdateHandoff(service: service, store: store, build: "27")
    await #expect(throws: (any Error).self) { try await handoff.recover() }
    #expect(service.events.isEmpty)
    try await handoff.discardKeepingPaused()
    #expect(service.events == ["stop"])
    #expect(!store.hasPendingInstallation)
    let record = UpdateResumeRecord(sourceBuild: "26", targetBuild: "27", registered: true, resumeSampling: true)
    #expect(!record.permitsAutomaticRecovery(build: "99"))
    #expect(record.permitsAutomaticRecovery(build: "26"))
    #expect(record.permitsAutomaticRecovery(build: "27"))
}

@MainActor @Test func corruptRecoveryNeverStartsServiceAndCanBeCleared() async throws {
    let defaults = UserDefaults(suiteName: "flowquota-update-test-" + UUID().uuidString)!
    defaults.set(Data("invalid".utf8), forKey: "pendingInstallation")
    let store = UpdateResumeStore(defaults: defaults)
    let service = UpdateTestService()
    let handoff = UpdateHandoff(service: service, store: store, build: "26")
    #expect(store.hasPendingInstallation)
    await #expect(throws: (any Error).self) { try await handoff.recover() }
    #expect(service.events.isEmpty)
    try await handoff.discardKeepingPaused()
    #expect(service.events == ["stop"])
    #expect(!store.hasPendingInstallation)
}

@MainActor @Test func updaterAllowsOnlyQuietAutomaticChecksAndExplicitManualChecks() throws {
    let suite = "flowquota-check-policy-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = AppUpdater(defaults: defaults)
    // SPUUpdater is not started and no HTTP or installed-app interaction occurs.
    let sparkle = Sparkle.SPUStandardUpdaterController(startingUpdater: false,
                                                       updaterDelegate: nil, userDriverDelegate: nil).updater
    #expect(throws: (any Error).self) { try controller.updater(sparkle, mayPerform: .updatesInBackground) }
    try controller.updater(sparkle, mayPerform: .updateInformation)
    controller.automaticChecks.setEnabled(false)
    #expect(throws: (any Error).self) { try controller.updater(sparkle, mayPerform: .updateInformation) }
    try controller.updater(sparkle, mayPerform: .updates)
    #expect(!controller.updaterShouldPromptForPermissionToCheck(forUpdates: sparkle))
}

@MainActor @Test func sparkleRecognizesLifecycleAndManualCheckDelegateSelectors() {
    let updater = AppUpdater()
    for selector in ["feedURLStringForUpdater:", "updater:mayPerformUpdateCheck:error:",
                     "updaterShouldPromptForPermissionToCheckForUpdates:",
                     "updater:didFindValidUpdate:", "updaterDidNotFindUpdate:error:",
                     "updater:didExtractUpdate:",
                     "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
                     "updater:didFinishUpdateCycleForUpdateCheck:error:"] {
        #expect(updater.responds(to: NSSelectorFromString(selector)))
    }
}

@MainActor @Test func installationFailureRecoversAgentAndKeepsErrorVisible() async throws {
    let service = UpdateTestService()
    let store = temporaryUpdateStore()
    let handoff = UpdateHandoff(service: service, store: store, build: "26")
    try await handoff.prepare(targetBuild: "27")
    let updater = AppUpdater(handoff: handoff)
    let sparkle = SPUStandardUpdaterController(startingUpdater: false,
                                               updaterDelegate: nil, userDriverDelegate: nil).updater
    updater.updater(sparkle, didFinishUpdateCycleFor: .updates,
                    error: NSError(domain: "test-install", code: 1))
    // The in-memory service fake completes immediately; let the recovery task run.
    for _ in 0..<100 where store.hasPendingInstallation { await Task.yield() }
    #expect(!store.hasPendingInstallation)
    #expect(!updater.readyToTerminate)
    #expect(service.events.last == "restore-active")
    #expect(updater.errorMessage?.contains("更新未完成") == true)
}
