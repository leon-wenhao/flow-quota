import Foundation
import FlowQuotaCore
import Network

public struct NetworkObservation: Sendable {
    public let state: NetworkState
    public let message: String
    public var generation: UInt64 = 0
    /// Eligible physical candidates, not every interface advertised by NWPath.
    public let interfaceIndexes: Set<UInt32>

    public var interfaceSelection: InterfaceSelection {
        guard state != .unknown else { return .unavailable(.networkUnavailable) }
        guard !interfaceIndexes.isEmpty else { return .unavailable(.noPhysicalInterface) }
        guard interfaceIndexes.count == 1, let index = interfaceIndexes.first else {
            return .unavailable(.ambiguousPhysicalInterfaces)
        }
        return .selected(index)
    }

    public init(state: NetworkState, message: String, generation: UInt64 = 0,
                interfaceIndexes: Set<UInt32> = []) {
        self.state = state
        self.message = message
        self.generation = generation
        self.interfaceIndexes = interfaceIndexes.filter { $0 > 0 }
    }
}

/// Cost selects the accounting category, not hotspot identity. Manual marks expire
/// on every path update, including a new connection using the same interface.
public final class NetworkObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "local.flowquota.network")
    private let lock = NSLock()
    private var state = NetworkTrackingState()

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            defer { lock.unlock() }
            let indexes = eligiblePhysicalInterfaceIndexes(
                path.availableInterfaces.map { (index: $0.index, type: $0.type) },
                usesInterfaceType: path.usesInterfaceType)
            state.update(isAvailable: path.status == .satisfied, isExpensive: path.isExpensive,
                         interfaceIndexes: indexes)
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public func snapshot() -> NetworkObservation {
        lock.lock()
        defer { lock.unlock() }
        return state.snapshot
    }

    public func markCurrentPath(_ marked: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        try state.markCurrentPath(marked)
    }
}

/// Deterministic state transitions shared by the system callback and unit tests.
/// No interface name, IP or SSID is treated as a durable connection identity.
struct NetworkTrackingState {
    private var automatic = NetworkObservation(state: .unknown, message: "正在识别网络。")
    private var isAvailable = false
    private var manualMark = false
    private var generation: UInt64 = 0

    var snapshot: NetworkObservation {
        if manualMark {
            return NetworkObservation(state: .hotspot,
                message: "当前连接已手动标记为热点并计量；网络状态更新后重新判断。", generation: generation,
                interfaceIndexes: automatic.interfaceIndexes)
        }
        var value = automatic
        value.generation = generation
        return value
    }

    mutating func markCurrentPath(_ marked: Bool) throws {
        guard isAvailable else {
            throw PlatformError.unavailable("网络尚未就绪或已断开，暂时无法标记热点。")
        }
        if manualMark != marked { generation &+= 1 }
        manualMark = marked
    }

    mutating func update(isAvailable: Bool, isExpensive: Bool, interfaceIndexes: Set<UInt32> = []) {
        self.isAvailable = isAvailable
        manualMark = false
        // The sampler uses this generation to discard cross-connection deltas.
        generation &+= 1
        if !isAvailable {
            automatic = NetworkObservation(state: .unknown, message: "当前网络不可用，不累计用量。")
        } else if isExpensive {
            automatic = NetworkObservation(state: .expensive,
                message: "系统报告高成本网络，采集期间自动计量；该信号不确认热点设备或运营商。",
                interfaceIndexes: interfaceIndexes)
        } else {
            automatic = NetworkObservation(state: .ordinary,
                message: "当前为普通网络，独立累计用量；若实际连接热点，可手动修正分类。",
                interfaceIndexes: interfaceIndexes)
        }
    }
}

/// availableInterfaces alone does not prove use. Never fall back to tunnels or
/// pick the first candidate when several physical interfaces remain possible.
func eligiblePhysicalInterfaceIndexes(
    _ interfaces: [(index: Int, type: NWInterface.InterfaceType)],
    usesInterfaceType: (NWInterface.InterfaceType) -> Bool
) -> Set<UInt32> {
    Set(interfaces.compactMap { interface in
        guard [.wifi, .wiredEthernet, .cellular].contains(interface.type),
              usesInterfaceType(interface.type),
              let index = UInt32(exactly: interface.index), index > 0 else { return nil }
        return index
    })
}
