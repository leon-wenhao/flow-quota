import Foundation

/// Callbacks, timeout and task cancellation may race on separate queues. Resolve
/// exactly once, including when the connection fails before continuation install.
final class XPCCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?
    private let connection: NSXPCConnection
    private var timer: DispatchWorkItem?

    init(connection: NSXPCConnection) { self.connection = connection }

    func install(_ continuation: CheckedContinuation<Data, any Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func startTimeout() {
        let timer = DispatchWorkItem { [weak self] in
            self?.resolve(.failure(PlatformError.timeout))
        }
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        self.timer = timer
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timer)
    }

    func failConnection(_ message: String) { resolve(.failure(PlatformError.connectionFailed(message))) }
    func fail(_ message: String) { resolve(.failure(PlatformError.unavailable(message))) }
    func succeed(_ data: Data) { resolve(.success(data)) }
    func cancel() { resolve(.failure(CancellationError())) }

    private func resolve(_ newResult: Result<Data, any Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = newResult
        let pending = continuation
        continuation = nil
        timer?.cancel()
        timer = nil
        lock.unlock()
        connection.interruptionHandler = nil
        connection.invalidationHandler = nil
        connection.invalidate()
        pending?.resume(with: newResult)
    }
}
