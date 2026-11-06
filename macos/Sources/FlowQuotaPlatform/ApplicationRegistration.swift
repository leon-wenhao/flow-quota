import CoreServices
import Foundation

/// Refresh this complete app's LaunchServices metadata before ServiceManagement
/// resolves BundleProgram. A replaced ad-hoc executable has a new code identity;
/// unregister/register alone can retain stale application metadata on macOS.
/// This updates only the supplied bundle and never changes execution permissions.
enum ApplicationRegistration {
    static func refresh(
        at application: URL = Bundle.main.bundleURL,
        register: @escaping @Sendable (URL, Bool) -> OSStatus = { LSRegisterURL($0 as CFURL, $1) }
    ) async throws {
        guard application.isFileURL, application.pathExtension == "app",
              Bundle(url: application)?.bundleIdentifier != nil else {
            throw PlatformError.unavailable("无法登记完整应用位置，请从安装目录中的 Flow Quota.app 启动。")
        }
        // LaunchServices is synchronous and may perform disk/IPC work. Complete
        // it off the main actor, including when finishing an unregister/register
        // pair whose caller was cancelled while waiting for the old agent to exit.
        let status = await Task.detached(priority: .utility) {
            register(application, true)
        }.value
        guard status == noErr else {
            throw PlatformError.unavailable("无法刷新应用的系统注册信息（错误码 \(status)），后台服务尚未重新注册。请重试恢复。")
        }
    }
}
