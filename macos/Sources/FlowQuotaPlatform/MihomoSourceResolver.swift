import Foundation
import FlowQuotaCore

/// Resolves a bounded, display-only source from controller metadata. A site is a
/// small allowlist classification, not proof of connection purpose or relay use.
struct MihomoSourceResolver: Sendable {
    private enum Site: String {
        case youtube, huya

        var name: String {
            switch self {
            case .youtube: "YouTube"
            case .huya: "虎牙直播"
            }
        }

        var domains: [String] {
            switch self {
            case .youtube: ["youtube.com", "youtu.be", "googlevideo.com", "ytimg.com"]
            case .huya: ["huya.com", "huya.tv", "huyacdn.com"]
            }
        }
    }

    func source(for connection: MihomoAPIConnection) -> MihomoProxySource {
        let resolved = identity(path: connection.metadata.processPath)
        // A shared proxy executable is evidence about the handler, not its caller.
        let isProxy = resolved.map { SystemProcessClassification(identity: $0).category == .sharedProxy } == true
        let app = isProxy ? nil : resolved
        let site = site(sniffHost: connection.metadata.sniffHost, host: connection.metadata.host)
        let name = site?.name ?? app?.name ?? "来源应用未确认"
        // Missing paths deliberately share a fixed unknown key. Process names,
        // arbitrary hosts, chain names and connection IDs must not create identities.
        let key = "\(app?.key ?? "unknown:source")|site:\(site?.rawValue ?? "none")"
        return MihomoProxySource(id: key, displayName: name + "（Clash）",
            connectionCount: 0, uploadedBytes: 0, downloadedBytes: 0,
            appIdentity: app, siteName: site?.name, viaClash: true)
    }

    private func identity(path: String?) -> AppIdentity? {
        guard let path, path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.hasSuffix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        // Reject directory-like metadata before Foundation standardizes symlink
        // paths: /tmp/.. may become /private rather than the filesystem root.
        guard let last = path.split(separator: "/", omittingEmptySubsequences: false).last,
              last != ".", last != ".." else { return nil }
        let executable = URL(fileURLWithPath: path).standardizedFileURL
        guard executable.path != "/" else { return nil }
        // Reuse app/helper grouping without PID guesses or basename identities.
        return ProcessIdentityResolver.identity(executable: executable)
    }

    private func site(sniffHost: String?, host: String?) -> Site? {
        // Mihomo v1.19.33 Metadata.RuleHost() selects every nonempty SniffHost.
        // Unrecognized or malformed sniffed evidence must not revive an older host.
        guard let sniffHost, !sniffHost.isEmpty else { return recognizedSite(host) }
        guard let sniffed = recognizedSite(sniffHost) else { return nil }
        // Conflicting recognized destinations cannot establish a single site.
        if let declared = recognizedSite(host), sniffed != declared { return nil }
        return sniffed
    }

    private func recognizedSite(_ value: String?) -> Site? {
        guard let value, value.utf8.count <= 254,
              value.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        var host = value.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253 else { return nil }
        // Reject URLs, ports, empty labels and malformed suffix lookalikes rather
        // than parsing arbitrary input as a URL or resolving anything over DNS.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { byte in
                    (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
                }
        }) else { return nil }
        for candidate in [Site.youtube, .huya] {
            if candidate.domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return candidate
            }
        }
        return nil
    }
}
