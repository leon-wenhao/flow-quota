import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

private func categorizedSnapshot(ordinaryPolicy: TrafficAlertPolicy = .disabled,
                                 pending: [TrafficAlertEvent] = []) throws -> AgentSnapshot {
    let day = try LocalDay.key(for: Date(), in: .current)
    let app = AppIdentity(key: "signed.test", name: "Test app")
    let categories = try TrafficCategory.allCases.map { category in
        TrafficCategorySnapshot(category: category,
            applications: [ApplicationSnapshot(identity: app,
                rule: category == .metered ? try QuotaRule(limitBytes: 100) : nil,
                usage: DailyUsage(appKey: app.key, day: day, uploadedBytes: category == .metered ? 60 : 500, downloadedBytes: 0))],
            applicationsAvailable: true, sampledAt: Date(),
            interfaceUsage: InterfaceUsage(day: day, uploadedBytes: category == .metered ? 120 : 1000, downloadedBytes: 0),
            interfaceSampledAt: category == .ordinary ? Date() : nil,
            interfaceMessage: "category \(category.rawValue)", trafficAlertPolicy: category == .metered ? .initial : ordinaryPolicy,
            trafficAlertEvents: pending.filter { $0.category == category })
    }
    return AgentSnapshot(generatedAt: Date(), network: .ordinary, readiness: .notInstalled,
        applications: categories[0].applications, message: "test", monitoring: .collecting,
        samplingEnabled: true, sampledAt: Date(), interfaceUsage: categories[0].interfaceUsage,
        trafficAlertPolicy: .initial, pendingTrafficAlerts: pending, trafficCategories: categories)
}

@MainActor @Test func categorySelectionChangesTotalsAppsRulesAndEditingDestinationTogether() async throws {
    let client = FakeAgentClient()
    client.state = try categorizedSnapshot()
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    #expect(state.totalUsage == 120)
    #expect(state.applications.first?.usage.totalBytes == 60)
    #expect(state.categoryPolicy == .initial)
    #expect(state.interfaceUsageIsPreserved)
    state.selectedTrafficCategory = .ordinary
    #expect(state.totalUsage == 1000)
    #expect(state.applications.first?.usage.totalBytes == 500)
    #expect(state.applications.first?.rule == nil)
    #expect(state.categoryPolicy == .disabled)
    #expect(!state.interfaceUsageIsPreserved)
    #expect(state.usageAvailable)
    #expect(state.menuBarUsageText == "1K")
    #expect(state.menuBarUsageAccessibilityLabel.contains("普通网络"))
    #expect(state.interfaceMenuHelp.contains("普通网络"))
    state.save(appKey: "signed.test", rule: try QuotaRule(limitBytes: 2000), acknowledged: {})
    await finishOperation(state)
    #expect(client.ruleCategories == [.ordinary])
    #expect(state.categoryPolicy == .disabled)
    state.selectedTrafficCategory = .metered
    #expect(state.totalUsage == 120)
    #expect(state.applications.first?.rule?.limitBytes == 100)
}

@MainActor @Test func notificationDeliveryUsesEventCategoryPolicyRegardlessOfViewedCategory() async throws {
    let client = FakeAgentClient()
    let day = try LocalDay.key(for: Date(), in: .current)
    let policy = try TrafficAlertPolicy(dailyInterfaceBytes: 1000, interfaceBurstBytes: nil,
        applicationBurstBytes: nil, version: 2)
    let ordinary = TrafficAlertEvent(category: .ordinary, day: day, kind: .dailyInterface,
        sourceName: "interface", observedBytes: 1200, thresholdBytes: 1000, windowSeconds: 0,
        observedSeconds: 0, policyVersion: 2, occurredAt: Date())
    let metered = TrafficAlertEvent(day: day, kind: .dailyInterface,
        sourceName: "interface", observedBytes: 1_200_000_000, thresholdBytes: 1_000_000_000, windowSeconds: 0,
        observedSeconds: 0, policyVersion: 1, occurredAt: Date())
    client.state = try categorizedSnapshot(ordinaryPolicy: policy, pending: [ordinary, metered])
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    #expect(Set(client.alertAcknowledgements) == [ordinary.id, metered.id])
    state.selectedTrafficCategory = .ordinary
    let history = try await state.loadTodayTrafficAlerts()
    #expect(history.map(\.category) == [.ordinary])
    #expect(client.historyCategories == [.ordinary])
    state.saveTrafficAlertPolicy(try TrafficAlertPolicy(dailyInterfaceBytes: nil,
        interfaceBurstBytes: nil, applicationBurstBytes: nil, version: 3), acknowledged: {})
    await finishOperation(state)
    #expect(client.policyCategories == [.ordinary])
}

@MainActor @Test func legacyServiceCannotFabricateOrdinaryDataOrWriteIntoMeteredSettings() async throws {
    let client = FakeAgentClient(monitoring: .collecting, sampledAt: Date(), interfaceUsage: try interfaceUsage())
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    #expect(state.totalUsage == 200)
    state.selectedTrafficCategory = .ordinary
    #expect(state.totalUsage == nil)
    #expect(!state.usageAvailable)
    #expect(!state.canEdit)
    #expect(state.categoryPolicy == nil)
    state.save(appKey: "signed.test", rule: try QuotaRule(limitBytes: 100), acknowledged: {})
    #expect(client.ruleCategories.isEmpty)
}

@MainActor @Test func capturedEditorCategoryCannotBeRedirectedByAnotherWindowSelection() async throws {
    let client = FakeAgentClient()
    client.state = try categorizedSnapshot()
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    let captured = state.selectedTrafficCategory
    state.selectedTrafficCategory = .ordinary
    state.save(appKey: "signed.test", rule: try QuotaRule(limitBytes: 200, version: 2),
        category: captured, acknowledged: {})
    await finishOperation(state)
    #expect(client.ruleCategories == [.metered])
    #expect(state.selectedTrafficCategory == .ordinary)
    let policy = try TrafficAlertPolicy(dailyInterfaceBytes: 2_000_000_000,
        interfaceBurstBytes: nil, applicationBurstBytes: nil, version: 2)
    state.saveTrafficAlertPolicy(policy, category: captured, acknowledged: {})
    await finishOperation(state)
    #expect(client.policyCategories == [.metered])
}
