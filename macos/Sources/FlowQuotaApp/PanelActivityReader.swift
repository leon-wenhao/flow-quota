import AppKit
import SwiftUI

/// MenuBarExtra can retain content after dismissal. Observe its actual native window rather than
/// relying only on onDisappear or scenePhase (an accessory app need not own a regular active scene).
struct PanelActivityReader: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ActivityView {
        let view = ActivityView()
        view.changed = changed
        return view
    }
    func updateNSView(_ nsView: ActivityView, context: Context) { nsView.changed = changed }
    static func dismantleNSView(_ nsView: ActivityView, coordinator: ()) { nsView.detach() }

    @MainActor final class ActivityView: NSView {
        var changed: (@MainActor (Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private var lastValue = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateActivity() }
                })
            }
            // Defer a SwiftUI state update out of NSViewRepresentable's layout pass.
            Task { @MainActor [weak self] in self?.updateActivity() }
        }

        func detach() {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens.removeAll()
            publish(false)
        }
        private func updateActivity() {
            let active = window.map { $0.isVisible && $0.isKeyWindow && $0.occlusionState.contains(.visible) } ?? false
            publish(active)
        }
        private func publish(_ active: Bool) {
            guard active != lastValue else { return }
            lastValue = active
            let callback = changed
            Task { @MainActor in callback?(active) }
        }
    }
}
