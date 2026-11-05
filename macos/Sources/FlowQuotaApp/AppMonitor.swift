import Foundation

/// One application-lifetime loop, independent of MenuBarExtra content creation or visibility.
/// Interval injection lets tests verify background delivery without a native panel or a long wait.
@MainActor final class AppMonitor {
    private let state: AppState
    private let interval: Duration?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    init(state: AppState, interval: Duration? = nil, defaults: UserDefaults = .standard) {
        self.state = state
        self.interval = interval
        self.defaults = defaults
    }

    func start() {
        guard task == nil else { return }
        let state = state
        let interval = interval
        let defaults = defaults
        task = Task { @MainActor in
            while !Task.isCancelled {
                await state.refresh()
                await state.notifications.refresh()
                // Read after each request: edits apply to the next wait without cancelling
                // an in-flight notification submission or starting a second polling loop.
                let delay = interval ?? .seconds(UsageRefreshPreference.seconds(in: defaults))
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
