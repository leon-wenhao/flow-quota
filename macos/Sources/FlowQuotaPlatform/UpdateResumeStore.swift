import Foundation

/// Shared with the LaunchAgent so registration during installation recovery cannot
/// start sampling before the UI has verified the saved intent. Contains no usage data.
public struct UpdateResumeRecord: Codable, Equatable, Sendable {
    public let sourceBuild: String
    public let targetBuild: String
    public let registered: Bool
    public let resumeSampling: Bool
    public let createdAt: Date

    public init(sourceBuild: String, targetBuild: String, registered: Bool,
                resumeSampling: Bool, createdAt: Date = Date()) {
        self.sourceBuild = sourceBuild
        self.targetBuild = targetBuild
        self.registered = registered
        self.resumeSampling = resumeSampling
        self.createdAt = createdAt
    }

    public func permitsAutomaticRecovery(build: String, now: Date = Date()) -> Bool {
        (build == sourceBuild || build == targetBuild)
            && (0...86_400).contains(now.timeIntervalSince(createdAt))
    }
}

public struct UpdateResumeStore {
    public static let suiteName = "local.flowquota.update-recovery"
    private let defaults: UserDefaults
    private let key = "pendingInstallation"

    public init(defaults: UserDefaults = UserDefaults(suiteName: suiteName)!) {
        self.defaults = defaults
    }

    public var hasPendingInstallation: Bool { defaults.object(forKey: key) != nil }

    public func read() throws -> UpdateResumeRecord? {
        guard hasPendingInstallation else { return nil }
        guard let data = defaults.data(forKey: key) else {
            throw PlatformError.unavailable("更新恢复标记损坏，请保持暂停并清除恢复标记。")
        }
        return try JSONDecoder().decode(UpdateResumeRecord.self, from: data)
    }

    public func save(_ record: UpdateResumeRecord) throws {
        defaults.set(try JSONEncoder().encode(record), forKey: key)
        try flush()
    }

    public func clear() throws {
        defaults.removeObject(forKey: key)
        try flush()
    }

    private func flush() throws {
        // This small handoff must reach preferences before another process starts.
        guard defaults.synchronize() else {
            throw PlatformError.unavailable("无法保存更新恢复状态，安装交接已停止。")
        }
    }
}
