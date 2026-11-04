import Foundation
import FlowQuotaCore
import Network

public struct NetworkObservation: Sendable {
    public let state: NetworkState
    public let message: String
}

/// Cost is a signal, not proof of tethering. Manual marking expires on path changes.
public final class NetworkObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "local.flowquota.network")
    private let lock = NSLock()
    private var observation = NetworkObservation(state: .unknown, message: "正在识别网络。")
    private var manualMark = false
    private var pathSignature: String?

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public func snapshot() -> NetworkObservation {
        lock.lock()
        defer { lock.unlock() }
        if manualMark {
            return NetworkObservation(state: .hotspot, message: "当前路径已手动标记为热点；网络状态更新后重新确认。")
        }
        return observation
    }

    public func markCurrentPath(_ marked: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard pathSignature != nil else {
            throw PlatformError.unavailable("网络状态尚未就绪，暂时无法标记热点。")
        }
        manualMark = marked
    }

    private func update(_ path: NWPath) {
        lock.lock()
        defer { lock.unlock() }
        // Interface names only delimit this session's path. They are never persisted
        // or treated as a durable hotspot identity (SSID access is not required).
        let signature = "\(path.status):\(path.isExpensive):" + path.availableInterfaces
            .map { "\($0.index):\($0.type)" }.sorted().joined(separator: ",")
        // Even a change on the same interface may be a different connection.
        // Do not retain a hotspot mark solely because its interface name matches.
        manualMark = false
        pathSignature = path.status == .satisfied ? signature : nil
        if path.status != .satisfied {
            observation = NetworkObservation(state: .unknown, message: "当前网络不可用。")
        } else if path.isExpensive {
            observation = NetworkObservation(state: .unknown, message: "检测到高成本网络，尚未确认热点；可手动标记。")
        } else {
            observation = NetworkObservation(state: .ordinary, message: "当前路径未报告为高成本网络；可手动标记热点。")
        }
    }
}
