import AppKit
import CoreServices

/// Ordinary quits keep the event loop running. Only a completed stop or explicit
/// consent to leave the collector unconfirmed permits the second termination call.
@MainActor final class AppQuitCoordinator {
    private let state: AppState
    private let suspendPolling: @MainActor () -> Void
    private let resumePolling: @MainActor () -> Void
    private let showProgress: @MainActor () -> Void
    private let hideProgress: @MainActor () -> Void
    private let confirmUIExit: @MainActor (String) -> Bool
    private let terminate: @MainActor () -> Void
    private(set) var stopping = false
    private var confirmingFailure = false
    private var systemReply: (@MainActor (Bool) -> Void)?
    private(set) var readyToTerminate = false

    init(state: AppState, suspendPolling: @escaping @MainActor () -> Void, resumePolling: @escaping @MainActor () -> Void,
         showProgress: @escaping @MainActor () -> Void, hideProgress: @escaping @MainActor () -> Void,
         confirmUIExit: @escaping @MainActor (String) -> Bool, terminate: @escaping @MainActor () -> Void) {
        self.state = state
        self.suspendPolling = suspendPolling
        self.resumePolling = resumePolling
        self.showProgress = showProgress
        self.hideProgress = hideProgress
        self.confirmUIExit = confirmUIExit
        self.terminate = terminate
    }

    func request(systemReply: (@MainActor (Bool) -> Void)? = nil) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        if stopping {
            // A shutdown arriving during an ordinary quit must receive its own
            // deferred reply rather than being cancelled by the earlier request.
            if self.systemReply == nil { self.systemReply = systemReply }
            if !confirmingFailure { showProgress() }
            return self.systemReply == nil ? .terminateCancel : .terminateLater
        }
        guard !state.busy else {
            state.reportError("操作尚未结束。请等待服务确认后再退出。")
            return .terminateCancel
        }
        stopping = true
        self.systemReply = systemReply
        suspendPolling()
        state.stopForTermination { [weak self] allowed in
            // AppState must clear its operation before polling resumes or an
            // alert runs a nested event loop. Queue completion after that cleanup.
            Task { @MainActor [weak self] in self?.finish(allowed) }
        }
        showProgress()
        return systemReply == nil ? .terminateCancel : .terminateLater
    }

    /// Preserve logout/shutdown/quit-all requests. Cancelling and later invoking
    /// terminate again would close this app but already have cancelled the system action.
    static func needsSystemReply(for event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        return [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut].contains(reason)
    }

    private func finish(_ allowed: Bool) {
        hideProgress()
        confirmingFailure = !allowed
        let shouldQuit = allowed || confirmUIExit(state.errorMessage ?? "本地服务尚未确认停止采集。请重试。")
        confirmingFailure = false
        stopping = false
        let reply = systemReply
        systemReply = nil
        if shouldQuit {
            readyToTerminate = true
            if let reply { reply(true) } else { terminate() }
        } else {
            reply?(false)
            resumePolling()
        }
    }
}
