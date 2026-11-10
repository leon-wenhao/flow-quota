import Foundation

/// A stable repository file, independent of Release titles, bodies and listing
/// order. Sparkle fetches and verifies this signed appcast before using its data.
struct GiteeUpdateFeed {
    static let branch = "codex/update-feeds"

    static func resolve(architecture: String = architecture) async throws -> URL {
        guard ["arm64", "x86_64"].contains(architecture) else {
            throw NSError(domain: "FlowQuota.UpdateSource", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "不支持的更新架构。"])
        }
        return URL(string: "https://gitee.com/Leon-wh/flow-quota/raw/\(branch)/updates/appcast-\(architecture).xml")!
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
