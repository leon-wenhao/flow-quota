import AppKit
import Foundation
import FlowQuotaCore
import SwiftUI
import Testing
@testable import FlowQuotaApp

private let clashCoreKey = "exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo"

@MainActor private func attributionState(proxyDay: String? = nil,
                                        status: MihomoProxyStatus = .observing) async throws -> AppState {
    let day = try LocalDay.key(for: Date(), in: .current)
    let chrome = AppIdentity(key: "app:/Applications/Google Chrome.app", name: "Google Chrome")
    let core = AppIdentity(key: clashCoreKey, name: "verge-mihomo")
    let apps = [chrome, core].map { identity in
        ApplicationSnapshot(identity: identity, rule: nil,
            usage: DailyUsage(appKey: identity.key, day: day, uploadedBytes: 1_000_000,
                downloadedBytes: 44_000_000))
    }
    let proxy = MihomoProxySnapshot(status: status, sources: [
        MihomoProxySource(id: "youtube", displayName: "YouTube（Clash）", connectionCount: 3,
            uploadedBytes: 10_000_000, downloadedBytes: 1_190_000_000,
            appIdentity: chrome, siteName: "YouTube"),
        MihomoProxySource(id: "huya", displayName: "虎牙直播（Clash）", connectionCount: 2,
            uploadedBytes: 5_000_000, downloadedBytes: 675_000_000,
            appIdentity: chrome, siteName: "虎牙直播")
    ], sampledAt: Date(), message: "模拟 API 数据；Clash 来源仅计本次运行，可能与每日应用归因重叠。",
       day: proxyDay ?? day, category: .ordinary)
    let interface = InterfaceUsage(day: day, uploadedBytes: 100_000_000, downloadedBytes: 2_000_000_000)
    let categories = TrafficCategory.allCases.map { category in
        TrafficCategorySnapshot(category: category, applications: apps, applicationsAvailable: true,
            sampledAt: Date(), interfaceUsage: interface, interfaceSampledAt: Date(), interfaceMessage: "Fixture",
            trafficAlertPolicy: .disabled, trafficAlertEvents: [], mihomoProxy: category == .ordinary ? proxy : nil)
    }
    let client = FakeAgentClient()
    client.state = AgentSnapshot(generatedAt: Date(), network: .ordinary, readiness: .notInstalled,
        applications: apps, message: "Fixture", monitoring: .collecting, samplingEnabled: true,
        trafficCategories: categories, mihomoProxy: proxy)
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    state.selectedTrafficCategory = .ordinary
    return state
}

@MainActor @Test func clashSourcesShareTheListWithoutBecomingLedgerAppsOrInflatingInterfaceTotals() async throws {
    let state = try await attributionState()
    #expect(state.applicationUsageItems.count == 3)
    #expect(state.applications.map(\.id) == ["app:/Applications/Google Chrome.app"])
    #expect(!state.applications.contains { $0.id == clashCoreKey })
    let proxyNames = state.applicationUsageItems.compactMap { item -> String? in
        if case .clash(let source, _) = item { return source.displayName }; return nil
    }
    #expect(proxyNames == ["YouTube（Clash）", "虎牙直播（Clash）"])
    #expect(state.totalUsage == 2_100_000_000)
    #expect(state.categoryApplications.count == 2) // Durable identities remain intact.
    state.selectedTrafficCategory = .metered
    #expect(state.applicationUsageItems.count == 1)
    #expect(state.categoryMihomoProxy == nil)
    #expect(state.totalUsage == 2_100_000_000)
}

@MainActor @Test func oldDayProxySourcesAreNotShownAsTodaysUsage() async throws {
    let state = try await attributionState(proxyDay: "2000-01-01")
    #expect(state.categoryMihomoProxy == nil)
    #expect(state.applicationUsageItems.count == 1)
}

@MainActor @Test func pausedProxySourcesRetainObservedUseAndExplainWhoseStateItIs() async throws {
    let state = try await attributionState(status: .paused)
    #expect(state.applicationUsageItems.first?.bytes == 1_200_000_000)
    #expect(state.clashAttributionNotice.contains("Flow Quota"))
    #expect(state.clashAttributionNotice.contains("Clash 本身"))
    var order = ApplicationListOrder()
    let ranked = state.applicationUsageItems
    order.reconcile(ranked)
    order.reconcile(Array(ranked.reversed()))
    #expect(order.ordered(Array(ranked.reversed())).map(\.id) == ranked.map(\.id))
}

/// A native render of fixtures only; this image is explicitly not live traffic.
@MainActor @Test func clashApplicationListRendersInOneSharedSurface() async throws {
    _ = NSApplication.shared
    let state = try await attributionState()
    let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
        Text("应用列表预览（模拟数据）").font(.title2.bold())
        ApplicationListView(state: state, edit: { _ in })
    }.padding(20).frame(width: 700, height: 430)
        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(png.count > 0)
    try png.write(to: URL(fileURLWithPath: "/tmp/flow-quota-clash-list-preview.png"))
}
