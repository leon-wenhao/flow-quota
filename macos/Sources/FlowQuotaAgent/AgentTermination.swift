import Darwin
import Dispatch
import Foundation

/// Process-lifetime signal sources; all lifecycle transitions run on the main actor.
/// SIGKILL/crashes cannot run cleanup; a timeout reports unconfirmed child cleanup.
@MainActor final class AgentTermination {
    private var sources: [any DispatchSourceSignal] = []
    private var shutdown: (@MainActor () async throws -> Void)?
    private var shutdownTask: Task<Void, Never>?
    private var deadline: DispatchWorkItem?
    private let timeout: DispatchTimeInterval
    private let completion: Completion
    private(set) var requested = false

    init(timeout: DispatchTimeInterval = .seconds(5),
         exit: @escaping @Sendable (Int32) -> Void = { Darwin.exit($0) }) {
        self.timeout = timeout
        completion = Completion(exit: exit)
    }

    func installSignalHandlers() throws {
        // SDK dispatch_source_create(3): signal sources do not change dispositions;
        // catch terminating signals. signal(3): caught handlers reset on exec, unlike
        // SIG_IGN, so Foundation's nettop child can still receive its own SIGTERM.
        for number in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.request() }
            }
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { _ in }
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESTART
            guard sigaction(number, &action, nil) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }
            sources.append(source)
            source.activate()
        }
    }

    /// May be called after a signal: shutdown waits until startup's task is available.
    func configure(shutdown: @escaping @MainActor () async throws -> Void) {
        precondition(self.shutdown == nil)
        self.shutdown = shutdown
        beginShutdownIfReady()
    }

    func request() {
        guard !requested else { return }
        requested = true
        let completion = completion
        let deadline = DispatchWorkItem { @Sendable in
            completion.finish(1, message: "停机超时；无法确认系统采样进程已回收。")
        }
        self.deadline = deadline
        // Independent of actor executors: a stuck startup/stop cannot delay exit forever.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        beginShutdownIfReady()
    }

    private func beginShutdownIfReady() {
        guard requested, shutdownTask == nil, let shutdown else { return }
        shutdownTask = Task {
            do {
                try await shutdown()
                deadline?.cancel()
                completion.finish(0)
            } catch {
                deadline?.cancel()
                completion.finish(1, message: "停机失败：\(error.localizedDescription)")
            }
        }
    }

    /// The watchdog and async cleanup may finish together. Only one owns process exit.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let exit: @Sendable (Int32) -> Void

        init(exit: @escaping @Sendable (Int32) -> Void) { self.exit = exit }

        func finish(_ status: Int32, message: String? = nil) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            if let message {
                FileHandle.standardError.write(Data("FlowQuotaAgent: \(message)\n".utf8))
            }
            exit(status)
        }
    }
}
