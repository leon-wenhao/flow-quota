import Foundation

/// Thresholds use decimal bytes; nil disables that check. One burst threshold
/// applies independently to every attributed app/system service, never their sum.
public struct TrafficAlertPolicy: Codable, Sendable, Equatable {
    public let dailyInterfaceBytes: Int64?
    public let interfaceBurstBytes: Int64?
    public let applicationBurstBytes: Int64?
    public let windowSeconds: Int
    public let cooldownSeconds: Int
    public let version: Int64

    public static let initial = try! TrafficAlertPolicy(dailyInterfaceBytes: 1_000_000_000,
        interfaceBurstBytes: 200_000_000, applicationBurstBytes: 200_000_000,
        windowSeconds: 180, cooldownSeconds: 600, version: 1)

    public init(dailyInterfaceBytes: Int64?, interfaceBurstBytes: Int64?, applicationBurstBytes: Int64?,
                windowSeconds: Int = 180, cooldownSeconds: Int = 600, version: Int64) throws {
        self.dailyInterfaceBytes = dailyInterfaceBytes
        self.interfaceBurstBytes = interfaceBurstBytes
        self.applicationBurstBytes = applicationBurstBytes
        self.windowSeconds = windowSeconds
        self.cooldownSeconds = cooldownSeconds
        self.version = version
        try validate()
    }

    /// Codable is transport only; revalidate at every service/storage boundary.
    public func validate() throws {
        guard [dailyInterfaceBytes, interfaceBurstBytes, applicationBurstBytes].allSatisfy({ $0 == nil || $0! > 0 }),
              (60...900).contains(windowSeconds), (60...86_400).contains(cooldownSeconds), version > 0 else {
            throw TrafficAlertError.invalidPolicy
        }
    }

    public func threshold(for kind: TrafficAlertKind) -> Int64? {
        switch kind {
        case .dailyInterface: dailyInterfaceBytes
        case .interfaceBurst: interfaceBurstBytes
        case .applicationBurst: applicationBurstBytes
        }
    }
}

public enum TrafficAlertError: Error, LocalizedError, Sendable {
    case invalidPolicy, invalidEvent, overflow, sourceLimit, bucketLimit, pendingEventLimit, eventLimit
    public var errorDescription: String? {
        switch self {
        case .invalidPolicy: "预警配置无效，请检查阈值、时间范围和版本。"
        case .invalidEvent: "预警事件字段无效。"
        case .overflow: "短时流量累计超出整数范围，已丢弃此窗口。"
        case .sourceLimit: "活跃应用超过 128 项，应用短时预警覆盖不完整；接口总量预警独立运行。"
        case .bucketLimit: "短时窗口超过 450 个采样桶，已重建窗口；请检查采样频率。"
        case .pendingEventLimit: "待保存的应用预警超过 128 个来源，部分预警尚未入队；请检查存储状态。"
        case .eventLimit: "今日预警记录已达 256 条上限；后续事件未记录，请调整阈值。"
        }
    }
}
