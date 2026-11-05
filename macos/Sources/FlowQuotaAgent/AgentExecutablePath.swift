import Foundation
import FlowQuotaPlatform

/// Resolves the running Agent executable independently of launchd's argv[0].
/// BundleProgram intentionally supplies a bundle-relative argument, while the
/// current working directory is not required to be the application bundle.
enum AgentExecutablePath {
    static func current() throws -> URL {
        guard let executable = Bundle.main.executableURL else {
            throw PlatformError.unavailable("无法解析本地服务的实际可执行文件路径。")
        }
        return executable.standardizedFileURL
    }
}
