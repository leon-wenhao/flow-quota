import Foundation

public enum InterfaceSelectionUnavailableReason: Equatable, Sendable {
    case networkUnavailable
    case noPhysicalInterface
    case ambiguousPhysicalInterfaces

    public var message: String {
        switch self {
        case .networkUnavailable: "网络不可用，接口总量未知。"
        case .noPhysicalInterface: "没有正在使用且可确定的物理接口，接口总量未知。"
        case .ambiguousPhysicalInterfaces: "存在多个可能使用的物理接口，接口总量未知。"
        }
    }
}

public enum InterfaceSelection: Equatable, Sendable {
    case selected(UInt32)
    case unavailable(InterfaceSelectionUnavailableReason)
}

/// Cumulative 64-bit interface octets, not application attribution or billed bytes.
public struct InterfaceCounterSnapshot: Equatable, Sendable {
    public let interfaceIndex: UInt32
    public let uploadedBytes: UInt64
    public let downloadedBytes: UInt64

    public init(interfaceIndex: UInt32, uploadedBytes: UInt64, downloadedBytes: UInt64) {
        self.interfaceIndex = interfaceIndex
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
    }
}

/// Call only with the one physical index selected by NetworkObservation.
/// A missing interface or failed/malformed read throws; it never becomes zero use.
public protocol InterfaceCounterReading: Sendable {
    func read(interfaceIndex: UInt32) throws -> InterfaceCounterSnapshot
}

public enum InterfaceCounterError: Error, LocalizedError, Equatable, Sendable {
    case invalidInterfaceIndex(UInt32)
    case systemCallFailed(Int32)
    case bufferLimitExceeded
    case malformedResponse
    case interfaceUnavailable(UInt32)
    case duplicateInterface(UInt32)
    case deltaOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidInterfaceIndex(let index): "接口索引无效：\(index)。"
        case .systemCallFailed(let code): "读取接口计数失败（系统错误 \(code)）。"
        case .bufferLimitExceeded: "接口计数响应超出缓冲区上限。"
        case .malformedResponse: "接口计数响应格式或长度无效。"
        case .interfaceUnavailable(let index): "接口 \(index) 的计数不可用。"
        case .duplicateInterface(let index): "接口 \(index) 的计数响应重复。"
        case .deltaOverflow: "接口流量增量超出整数范围。"
        }
    }
}

/// Read-only public SDK sysctl route MIB; no subprocess, socket traffic or 32-bit
/// getifaddrs counters. Syscall and message parsing are separate for mock tests.
public struct SystemInterfaceTrafficCounter: InterfaceCounterReading {
    private let reader: InterfaceSysctlReader

    public init() { reader = InterfaceSysctlReader() }

    init(reader: InterfaceSysctlReader) { self.reader = reader }

    public func read(interfaceIndex: UInt32) throws -> InterfaceCounterSnapshot {
        let data = try reader.read(interfaceIndex: interfaceIndex)
        return try InterfaceTrafficMessages.parse(data, interfaceIndex: interfaceIndex)
    }
}
