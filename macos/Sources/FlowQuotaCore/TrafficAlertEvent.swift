import Foundation

public enum TrafficAlertKind: String, Codable, Sendable, CaseIterable {
    case dailyInterface, interfaceBurst, applicationBurst
    public var title: String {
        switch self {
        case .dailyInterface: "今日接口用量达到提醒阈值"
        case .interfaceBurst: "检测到短时间大量流量"
        case .applicationBurst: "应用或后台服务流量预警"
        }
    }
}

/// Current-day evidence + outbox. sourceKey is empty only for interface events.
/// scheduledAt records OS scheduling acceptance, never a seen-banner guarantee.
public struct TrafficAlertEvent: Codable, Sendable, Equatable, Identifiable {
    public let category: TrafficCategory
    public let id: String
    public let day: String
    public let kind: TrafficAlertKind
    public let sourceKey: String
    public let sourceName: String
    public let observedBytes: Int64
    public let thresholdBytes: Int64
    public let windowSeconds: Int
    public let observedSeconds: Int
    public let policyVersion: Int64
    public let occurredAt: Date
    public let scheduledAt: Date?

    public init(category: TrafficCategory = .metered, id: String = UUID().uuidString, day: String, kind: TrafficAlertKind,
                sourceKey: String = "", sourceName: String, observedBytes: Int64,
                thresholdBytes: Int64, windowSeconds: Int, observedSeconds: Int,
                policyVersion: Int64, occurredAt: Date, scheduledAt: Date? = nil) {
        self.category = category
        self.id = id; self.day = day; self.kind = kind; self.sourceKey = sourceKey
        self.sourceName = sourceName; self.observedBytes = observedBytes
        self.thresholdBytes = thresholdBytes; self.windowSeconds = windowSeconds
        self.observedSeconds = observedSeconds; self.policyVersion = policyVersion
        self.occurredAt = occurredAt; self.scheduledAt = scheduledAt
    }

    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        self.init(category: try v.decodeIfPresent(TrafficCategory.self, forKey: .category) ?? .metered,
            id: try v.decode(String.self, forKey: .id), day: try v.decode(String.self, forKey: .day),
            kind: try v.decode(TrafficAlertKind.self, forKey: .kind),
            sourceKey: try v.decode(String.self, forKey: .sourceKey), sourceName: try v.decode(String.self, forKey: .sourceName),
            observedBytes: try v.decode(Int64.self, forKey: .observedBytes), thresholdBytes: try v.decode(Int64.self, forKey: .thresholdBytes),
            windowSeconds: try v.decode(Int.self, forKey: .windowSeconds), observedSeconds: try v.decode(Int.self, forKey: .observedSeconds),
            policyVersion: try v.decode(Int64.self, forKey: .policyVersion), occurredAt: try v.decode(Date.self, forKey: .occurredAt),
            scheduledAt: try v.decodeIfPresent(Date.self, forKey: .scheduledAt))
    }

    public func validate() throws {
        guard UUID(uuidString: id) != nil, LocalDay.isValidKey(day),
              !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceName.utf8.count <= 256, !sourceName.contains("\0"),
              sourceKey.utf8.count <= 2048, !sourceKey.contains("\0"),
              sourceKey == sourceKey.precomposedStringWithCanonicalMapping,
              (kind == .applicationBurst) == !sourceKey.isEmpty,
              observedBytes >= thresholdBytes, thresholdBytes > 0, policyVersion > 0,
              occurredAt.timeIntervalSince1970.isFinite, occurredAt.timeIntervalSince1970 > 0,
              occurredAt.timeIntervalSince1970 < 253_402_300_800,
              (kind == .dailyInterface ? windowSeconds == 0 && observedSeconds == 0
               : (60...900).contains(windowSeconds) && (1...windowSeconds).contains(observedSeconds)) else {
            throw TrafficAlertError.invalidEvent
        }
    }
}
