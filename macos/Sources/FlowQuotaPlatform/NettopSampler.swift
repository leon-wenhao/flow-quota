import Foundation
import Darwin

/// One long-lived system utility, drained on a dedicated I/O queue (never UI/actor executors).
/// Bounded buffering may drop frames under pressure; sequence gaps force the ledger to rebaseline.
public final class NettopSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let io = DispatchQueue(label: "local.flowquota.nettop", qos: .utility)

    public init() {}

    public func frames(interval: Int = 2) -> AsyncThrowingStream<NettopFrame, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            continuation.onTermination = { [weak self] _ in self?.stop() }
            io.async { [self] in
                let child = Process()
                var terminal: SamplerTerminal?
                child.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
                child.arguments = ["-P", "-L", "0", "-s", String(max(1, min(interval, 60))),
                                   "-n", "-x", "-t", "external", "-J", "bytes_in,bytes_out"]
                child.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "TERM": "dumb"]
                // Never retain other processes' names, endpoints or arbitrary diagnostic text.
                child.standardError = FileHandle.nullDevice
                do {
                    let output = try SamplerTerminal()
                    terminal = output
                    // nettop also watches stdin in CSV mode. Inheriting launchd's
                    // /dev/null leaves EOF permanently readable and spins its dispatch
                    // source. Share the idle PTY slave for input and line-buffered output.
                    child.standardInput = output.writer
                    child.standardOutput = output.writer
                    try launch(child)
                    try output.writer.close()
                    var parser = NettopParser()
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    while true {
                        // A single POSIX read returns available bytes. Foundation's
                        // read(upToCount:) can wait for a full buffer on a live pipe.
                        let count = buffer.withUnsafeMutableBytes {
                            Darwin.read(output.reader.fileDescriptor, $0.baseAddress, $0.count)
                        }
                        if count < 0, errno == EINTR { continue }
                        if count < 0, errno == EIO { break }
                        guard count >= 0 else {
                            throw PlatformError.unavailable("无法读取系统采样输出。")
                        }
                        if count == 0 { break }
                        for frame in try parser.append(Data(buffer.prefix(count))) { continuation.yield(frame) }
                    }
                    child.waitUntilExit()
                    if isCancelled { continuation.finish() }
                    else {
                        continuation.finish(throwing: PlatformError.unavailable(
                            "系统采集进程已退出（状态 \(child.terminationStatus)），请重启采集；中断期间用量未知。"))
                    }
                } catch {
                    if child.isRunning { child.terminate() }
                    if child.processIdentifier > 0 { child.waitUntilExit() }
                    continuation.finish(throwing: error)
                }
                try? terminal?.reader.close()
                try? terminal?.writer.close()
                clear(child)
            }
        }
    }

    public func stop() {
        lock.lock()
        cancelled = true
        let child = process
        lock.unlock()
        if let child, child.isRunning { child.terminate() }
    }

    /// Stream cancellation resumes its consumer before the I/O queue has reaped
    /// the child. Service shutdown must wait for both before acknowledging stop.
    public func stopAndWait() async {
        stop()
        await withCheckedContinuation { continuation in
            io.async { continuation.resume() }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func launch(_ child: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, process == nil else { throw CancellationError() }
        // Serialize launch with stop so a cancelled sampler cannot leave an untracked child.
        try child.run()
        process = child
    }

    private func clear(_ child: Process) {
        lock.lock()
        defer { lock.unlock() }
        if process === child { process = nil }
    }

    deinit { stop() }
}
