import AppKit
import SwiftUI

/// A normal native window keeps progress visible even when the menu panel closes.
/// It has no close button: dismissing it must not cancel an unconfirmed stop request.
@MainActor final class QuitProgressWindow: NSWindowController {
    init(state: AppState) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 112),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "正在退出 Flow Quota"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: QuitProgressView(state: state).appAppearance())
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct QuitProgressView: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 16) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 6) {
                Text(state.operation ?? "正在停止采集").font(.headline)
                Text("确认停止后会自动退出。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 380, height: 112)
        .accessibilityElement(children: .combine)
    }
}
