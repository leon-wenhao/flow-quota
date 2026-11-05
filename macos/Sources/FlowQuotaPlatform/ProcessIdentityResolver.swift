import Foundation
import Darwin
import FlowQuotaCore

public struct ResolvedProcessCounter: Sendable {
    public let processKey: String
    public let identity: AppIdentity
    public let startedAt: Date?
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64

    public init(processKey: String, identity: AppIdentity, uploadedBytes: Int64, downloadedBytes: Int64,
                startedAt: Date? = nil) {
        self.processKey = processKey
        self.identity = identity
        self.startedAt = startedAt
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
    }
}

/// Public libproc/sysctl metadata validates PID incarnation; path is the durable app key.
/// Bundle grouping is a path-based heuristic, not signing-verified traffic attribution.
public struct ProcessIdentityResolver: Sendable {
    private let readBirth: @Sendable (Int32) -> ProcessBirthStamp?
    private let readPath: @Sendable (Int32) -> String?

    public init() {
        readBirth = ProcessBirthReader().read
        readPath = Self.executablePath
    }

    /// Synchronous injection verifies PID reuse and denied metadata without a
    /// system sampler, privileged helper, or generated network traffic.
    init(readBirth: @escaping @Sendable (Int32) -> ProcessBirthStamp?,
         readPath: @escaping @Sendable (Int32) -> String?) {
        self.readBirth = readBirth
        self.readPath = readPath
    }

    public func resolve(_ counter: ProcessCounter, capturedAt: Date = Date()) -> ResolvedProcessCounter? {
        guard counter.pid > 0, counter.uploadedBytes >= 0, counter.downloadedBytes >= 0,
              let before = readBirth(counter.pid), before.timeInterval <= capturedAt.timeIntervalSince1970,
              let path = readPath(counter.pid), path.hasPrefix("/"), !path.contains("\0"),
              let after = readBirth(counter.pid), before == after else { return nil }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let identity = Self.identity(executable: executable)
        return ResolvedProcessCounter(processKey: "\(counter.pid):\(before.token):\(executable.path)",
            identity: identity, uploadedBytes: counter.uploadedBytes, downloadedBytes: counter.downloadedBytes,
            startedAt: Date(timeIntervalSince1970: before.timeInterval))
    }

    static func identity(executable: URL) -> AppIdentity {
        var cursor = executable.deletingLastPathComponent()
        var app: URL?
        // Outermost .app owns nested helper bundles. Shared daemons remain separate.
        while cursor.path != "/" {
            if cursor.pathExtension == "app" { app = cursor }
            cursor.deleteLastPathComponent()
        }
        let root = app ?? executable
        let bundle = app.flatMap(Bundle.init(url:))
        let display = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? root.deletingPathExtension().lastPathComponent
        let name = display.isEmpty ? root.lastPathComponent : display
        return AppIdentity(key: ((app == nil ? "exec:" : "app:") + root.path).precomposedStringWithCanonicalMapping,
                           name: name.precomposedStringWithCanonicalMapping)
    }

    private static func executablePath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN in the public SDK.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0, count < buffer.count else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }
}
