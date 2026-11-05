import Foundation

public struct ProcessCounter: Sendable, Equatable {
    public let pid: Int32
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64
}

public struct NettopFrame: Sendable {
    public let sequence: UInt64
    public let capturedAt: Date
    /// Continuous monotonic nanoseconds from SamplingClock, including system sleep.
    public let uptime: UInt64
    public let counters: [ProcessCounter]
}

/// Fixed documented columns; displayed process names are never application identities.
/// Each repeated CSV header starts a new frame. Only complete frames are published.
struct NettopParser {
    private var pending = Data()
    private var counters: [ProcessCounter] = []
    private var pids = Set<Int32>()
    private var startedAt: Date?
    private var uptime: UInt64 = 0
    private var sequence: UInt64 = 0
    static let maximumFrameRows = 4096

    mutating func append(_ data: Data, now: Date = Date(), uptime: UInt64 = SamplingClock.nowNanoseconds)
        throws -> [NettopFrame] {
        pending.append(data)
        guard pending.count <= 1_048_576 else { throw error("采样输出行超过安全上限。") }
        var frames: [NettopFrame] = []
        while let newline = pending.firstIndex(of: 10) {
            let raw = pending[..<newline]
            guard let line = String(data: raw, encoding: .utf8) else { throw error("采样输出编码无效。") }
            pending.removeSubrange(...newline)
            if let frame = try accept(line.trimmingCharacters(in: .newlines), now: now, uptime: uptime) {
                frames.append(frame)
            }
        }
        return frames
    }

    private mutating func accept(_ line: String, now: Date, uptime: UInt64) throws -> NettopFrame? {
        if line == ",bytes_in,bytes_out," {
            let previous = startedAt.map {
                NettopFrame(sequence: sequence, capturedAt: $0, uptime: self.uptime, counters: counters)
            }
            sequence += 1
            startedAt = now
            self.uptime = uptime
            counters = []
            pids = []
            return previous
        }
        if line.isEmpty { return nil }
        guard startedAt != nil else { throw error("无法识别 nettop 输出表头。") }
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
        // A comma in the display name cannot change the three fixed trailing columns.
        guard parts.count >= 4, parts.last == "",
              let input = Int64(parts[parts.count - 3]), input >= 0,
              let output = Int64(parts[parts.count - 2]), output >= 0 else {
            throw error("nettop 计数字段无效。")
        }
        let name = parts.dropLast(3).joined(separator: ",")
        guard let pidText = name.split(separator: ".").last,
              let pid = Int32(pidText), pid > 0,
              pids.insert(pid).inserted, counters.count < Self.maximumFrameRows else {
            throw error("nettop 进程标识重复、无效或数量过多。")
        }
        counters.append(ProcessCounter(pid: pid, uploadedBytes: output, downloadedBytes: input))
        return nil
    }

    private func error(_ message: String) -> PlatformError { .unavailable(message) }
}
