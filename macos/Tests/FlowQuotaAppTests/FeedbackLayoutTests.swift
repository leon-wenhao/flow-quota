import AppKit
import FlowQuotaCore
import SwiftUI
import Testing
@testable import FlowQuotaApp

/// Native, fixture-only scroll measurements. No XPC, sampling, or OS permission requests.
@MainActor @Test func settingsScrollGeometryStaysFixedAcrossOperationFeedback() async throws {
    _ = NSApplication.shared
    let client = FakeAgentClient()
    client.state = AgentSnapshot(generatedAt: Date(), network: .expensive, readiness: .notInstalled,
        applications: [], message: "Fixture only", monitoring: .paused, trafficAlertPolicy: .initial)
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    let host = NSHostingView(rootView: PanelView(state: state, showSettings: true))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 680),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 420, height: 680)
    defer { window.close() }
    await settleFeedbackLayout(host)
    let scroll = try #require(findScrollView(host))
    let document = try #require(scroll.documentView)
    document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentSize.height)))
    await settleFeedbackLayout(host)
    let baseline = FeedbackScrollGeometry(scroll)
    #expect(baseline.offset.y > 0)
    for operation in ["正在保存流量预警配置", "正在保存规则", "正在启用本地服务", "正在更新热点标记", "正在修复开发服务"] {
        let gate = FeedbackOperationGate()
        state.perform(operation) { state in
            await gate.wait()
            state.reportNotice("提醒配置已持久化；短时窗口重新积累。")
        }
        await settleFeedbackLayout(host)
        #expect(state.busy)
        #expect(FeedbackScrollGeometry(scroll) == baseline, "Loading feedback: \(operation)")
        gate.resume()
        await finishOperation(state)
        await settleFeedbackLayout(host)
        #expect(FeedbackScrollGeometry(scroll) == baseline, "Saved feedback: \(operation)")
        state.reportError(String(repeating: "操作失败的详细原因；", count: 100))
        await settleFeedbackLayout(host)
        #expect(FeedbackScrollGeometry(scroll) == baseline, "Long failure feedback: \(operation)")
        #expect(ServiceFeedbackPresentation(state: state).hasError)
        state.clearMessages()
        await settleFeedbackLayout(host)
        #expect(FeedbackScrollGeometry(scroll) == baseline)
    }
}

@MainActor @Test func quotaEditorDoesNotInsertALockRowWhileSaving() async throws {
    _ = NSApplication.shared
    let app = try application()
    let client = FakeAgentClient(applications: [app], monitoring: .paused)
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    let host = NSHostingView(rootView:
        ScrollView { QuotaEditor(application: app, state: state, done: {}).padding(16) }
            .frame(width: 420, height: 400))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 420, height: 400)
    defer { window.close() }
    await settleFeedbackLayout(host)
    let scroll = try #require(findScrollView(host))
    let document = try #require(scroll.documentView)
    document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentSize.height)))
    await settleFeedbackLayout(host)
    let baseline = FeedbackScrollGeometry(scroll)
    let gate = FeedbackOperationGate()
    state.perform("正在保存规则") { _ in await gate.wait() }
    await settleFeedbackLayout(host)
    #expect(!state.canEdit)
    #expect(FeedbackScrollGeometry(scroll) == baseline)
    gate.resume()
    await finishOperation(state)
    await settleFeedbackLayout(host)
    #expect(state.canEdit)
    #expect(FeedbackScrollGeometry(scroll) == baseline)
}

private struct FeedbackScrollGeometry: Equatable {
    let viewport: NSRect
    let document: NSRect
    let offset: NSPoint
    @MainActor init(_ scroll: NSScrollView) {
        viewport = scroll.frame
        document = scroll.documentView!.frame
        offset = scroll.contentView.bounds.origin
    }
}

@MainActor private func findScrollView(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { findScrollView($0) }.first
}

@MainActor private func settleFeedbackLayout(_ host: NSView) async {
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(30))
    host.layoutSubtreeIfNeeded()
}

@MainActor private final class FeedbackOperationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
