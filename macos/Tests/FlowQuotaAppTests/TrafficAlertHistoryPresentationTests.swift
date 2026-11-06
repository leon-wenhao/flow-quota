import AppKit
import FlowQuotaCore
import SwiftUI
import Testing
@testable import FlowQuotaApp

@Suite(.serialized) @MainActor
struct TrafficAlertHistoryPresentationTests {
    init() { _ = NSApplication.shared }

    private let healthy = "每日接口预警运行中。 接口短时预警运行中；未知来源不影响接口提醒。 应用短时预警运行中；共享下载服务不推测原始请求方。"

    @Test func normalStatusDoesNotCompeteWithHistory() {
        #expect(TrafficAlertDiagnostics.warning(in: healthy) == nil)
        #expect(TrafficAlertDiagnostics.warning(in: "每日接口预警已关闭。 接口短时预警已关闭。 应用短时预警已关闭。") == nil)
        #expect(TrafficAlertDiagnostics.warning(in: "接口短时窗口已清空；等待连续采样。 应用短时预警等待连续采样。") == nil)
    }

    @Test func readSamplingQueueAndCapacityFailuresAreNeverHidden() {
        for failure in [
            "接口预警配置读取失败：数据库忙。",
            "应用预警配置读取失败：无法读取配置。",
            "每日接口预警未完成：用量读取失败。",
            "接口短时预警未完成：数值溢出。",
            "接口预警尚未保存，将重试：磁盘空间不足。",
            "应用预警尚未保存，将重试：写入失败。",
            "已获得的预警尚未保存：写入失败。",
            "应用预警覆盖不完整：活跃应用超过 128 项。",
            "接口预警未完成：今日预警记录已达 256 条上限。",
            "应用采样失败；应用短时窗口已清空，接口预警独立运行。",
            "未来服务的新异常文本。"
        ] {
            #expect(TrafficAlertDiagnostics.warning(in: healthy + " " + failure) == failure)
        }
    }

    @Test func historyWarningIsSharedWithOverviewAndDoesNotLeakExpiredState() async {
        let client = FakeAgentClient()
        let state = AppState(client: client, scheduler: FakeReminderScheduler())
        client.state = AgentSnapshot(generatedAt: Date(), network: .expensive, readiness: .notInstalled,
            applications: [], message: "Fixture", monitoring: .collecting,
            trafficAlertMessage: healthy + " 应用预警尚未保存，将重试：磁盘已满。")
        await state.refresh()
        #expect(state.trafficAlertWarning == "应用预警尚未保存，将重试：磁盘已满。")
        state.selectedTrafficCategory = .ordinary
        #expect(state.trafficAlertWarning != nil)
        client.fetchFails = true
        await state.refresh()
        #expect(state.trafficAlertWarning == nil)
    }

    @Test(arguments: [CGFloat(500), CGFloat(720)])
    func tableRendersReadableColumnsAtMinimumAndWideWidths(width: CGFloat) async throws {
        let events = try fixtures()
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 14) {
            Text("预警记录 · 模拟数据").font(.title2.bold())
            TrafficAlertHistoryTable(events: events)
        }.padding(12).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
        let window = makeWindow(host, width: width)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == width)
        #expect(host.fittingSize.height < 400)
        try save(host, to: "/tmp/flow-quota-alert-history-\(Int(width)).png")
    }

    @Test func emptyHistoryKeepsTableAndPlaceholder() async throws {
        let host = NSHostingView(rootView: TrafficAlertHistoryTable(events: []).frame(width: 500))
        let window = makeWindow(host, width: 500)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(40))
        #expect(host.fittingSize.width == 500)
        #expect(host.fittingSize.height >= 150)
        try save(host, to: "/tmp/flow-quota-alert-history-empty.png")
    }

    @Test func rowWhitespaceOpensAndClosesFullDetails() async throws {
        let host = NSHostingView(rootView: TrafficAlertHistoryTable(events: Array(try fixtures().prefix(1))).frame(width: 500))
        let window = makeWindow(host, width: 500)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(40))
        let collapsed = host.fittingSize.height
        // The left padding below the table header is part of the entire row button.
        click(window, host: host, point: CGPoint(x: 7, y: 65))
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > collapsed + 60)
        click(window, host: host, point: CGPoint(x: 7, y: 65))
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - collapsed) < 1)
    }

    @Test(arguments: [CGFloat(500), CGFloat(720)])
    func appEvidenceLoadsOnlyWhenExpandedAndRendersDirections(width: CGFloat) async throws {
        let today = try LocalDay.key(for: Date(), in: .current)
        let apps = TrafficAlertApplications(items: [
            TrafficAlertApplication(identity: AppIdentity(key: "signed:browser", name: "浏览器"),
                uploadedBytes: 12_000_000, downloadedBytes: 180_000_000),
            TrafficAlertApplication(identity: AppIdentity(key: "exec:/usr/libexec/nsurlsessiond", name: "nsurlsessiond"),
                uploadedBytes: 1_000_000, downloadedBytes: 30_000_000),
            TrafficAlertApplication(identity: AppIdentity(key: "signed:chat", name: "微信"),
                uploadedBytes: 5_000_000, downloadedBytes: 2_000_000)
        ], observedAt: Date())
        let event = TrafficAlertEvent(day: today, kind: .interfaceBurst, sourceName: "本机计量接口",
            observedBytes: 240_000_000, thresholdBytes: 200_000_000, windowSeconds: 180,
            observedSeconds: 125, policyVersion: 1, occurredAt: Date(), applications: apps)
        var reads = 0
        let host = NSHostingView(rootView: TrafficAlertHistoryTable(events: [event.summaryOnly()], loadDetails: { _ in
            reads += 1
            return event
        }).frame(width: width))
        let window = makeWindow(host, width: width)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(40))
        #expect(reads == 0)
        let collapsed = host.fittingSize.height
        try save(host, to: "/tmp/flow-quota-alert-applications-collapsed-\(Int(width)).png")
        click(window, host: host, point: CGPoint(x: 7, y: 65))
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        #expect(reads == 1)
        #expect(host.fittingSize.width == width)
        #expect(host.fittingSize.height > collapsed + 100)
        host.frame.size.height = host.fittingSize.height
        try save(host, to: "/tmp/flow-quota-alert-applications-expanded-\(Int(width)).png")
        click(window, host: host, point: CGPoint(x: 7, y: 65))
        try await Task.sleep(for: .milliseconds(40))
        #expect(abs(host.fittingSize.height - collapsed) < 1)
    }

    private func fixtures() throws -> [TrafficAlertEvent] {
        let today = try LocalDay.key(for: Date(), in: .current)
        return TrafficAlertKind.allCases.enumerated().map { index, kind in
            TrafficAlertEvent(day: today, kind: kind,
                sourceKey: kind == .applicationBurst ? "exec:/usr/libexec/nsurlsessiond" : "",
                sourceName: kind == .applicationBurst ? "nsurlsessiond" : "本机计量接口",
                observedBytes: kind == .dailyInterface ? 1_000_000_000 : 254_000_000,
                thresholdBytes: kind == .dailyInterface ? 1_000_000_000 : 200_000_000,
                windowSeconds: kind == .dailyInterface ? 0 : 180,
                observedSeconds: kind == .dailyInterface ? 0 : 125,
                policyVersion: 1, occurredAt: Date().addingTimeInterval(Double(-index * 300)),
                scheduledAt: kind == .applicationBurst ? nil : Date())
        }
    }

    private func makeWindow<Content: View>(_ host: NSHostingView<Content>, width: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let size = CGSize(width: width, height: host.fittingSize.height)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame.size = size
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func click<Content: View>(_ window: NSWindow, host: NSHostingView<Content>, point: CGPoint) {
        let location = CGPoint(x: point.x, y: host.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
    }

    private func save<Content: View>(_ host: NSHostingView<Content>, to path: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
