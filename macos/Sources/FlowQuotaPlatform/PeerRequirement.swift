import Foundation
import Security

public enum PlatformError: LocalizedError, Sendable {
    case unavailable(String)
    case malformedReply
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .malformedReply: return "本地服务返回了无法识别的数据。"
        case .timeout: return "本地服务响应超时，请检查后台服务状态。"
        }
    }
}

public enum PeerRequirement {
    /// Pin XPC messages to the exact embedded executable's designated requirement.
    /// An identifier alone is forgeable; ad-hoc development builds use a cdhash.
    public static func string(forExecutable url: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else {
            throw PlatformError.unavailable("无法验证本地组件身份，请重新构建完整应用。")
        }
        return text as String
    }

    public static func containingApp(executable: URL) throws -> URL {
        let app = executable.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app" else {
            throw PlatformError.unavailable("请从完整 Flow Quota.app 启动本地服务。")
        }
        return app
    }
}
