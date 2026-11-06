import Darwin
import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import FlowQuotaStore

@main @MainActor struct FlowQuotaAgent {
    private static var activeListener: NSXPCListener?
    private static var activeServer: AgentServer?
    private static let termination = AgentTermination()
    static func main() async {
        // SQLite sidecars and the database must be private to this local user.
        umask(0o077)
        do {
            try termination.installSignalHandlers()
            let diagnostic = CommandLine.arguments.contains("--snapshot")
            let executable = try AgentExecutablePath.current()
            let app = diagnostic ? nil : try PeerRequirement.containingApp(executable: executable)
            let path = try databasePath(diagnostic: diagnostic)
            try ServiceStorage.prepareDatabase(at: path)
            let store = try QuotaStore(path: path.path)
            let runtime = AgentRuntime(store: store)
            let startup = Task { @MainActor in
                try Task.checkCancellation()
                try await runtime.startRetentionMaintenance()
                if diagnostic {
                    if let index = CommandLine.arguments.firstIndex(of: "--sample-seconds"),
                       index + 1 < CommandLine.arguments.count,
                       let seconds = UInt64(CommandLine.arguments[index + 1]), (4...60).contains(seconds) {
                        _ = try await runtime.handle(.startMonitoring)
                        try await Task.sleep(for: .milliseconds(500))
                        if CommandLine.arguments.contains("--mark-hotspot") {
                            _ = try await runtime.handle(.setHotspotOverride(true))
                        }
                        try await Task.sleep(for: .seconds(seconds))
                    }
                    let reply = try await runtime.handle(.snapshot)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    print(String(decoding: try encoder.encode(reply), as: UTF8.self))
                    _ = try await runtime.handle(.stopProtection)
                    return
                }
                guard let app else { throw PlatformError.unavailable("缺少完整应用容器。") }
                // A narrowly scoped development switch enables installation/XPC checks
                // without opening nettop or reading live interface counters on a hotspot.
                if ProcessInfo.processInfo.environment["FLOW_QUOTA_VERIFY_PAUSED"] == "1" {
                    guard Bundle(url: app)?.object(forInfoDictionaryKey: "FlowQuotaDevelopmentBuild") as? Bool == true else {
                        throw PlatformError.unavailable("暂停启动自检只适用于开发构建。")
                    }
                    _ = try await runtime.handle(.stopProtection)
                } else if UpdateResumeStore().hasPendingInstallation {
                    _ = try await runtime.handle(.stopProtection)
                } else {
                    _ = try await runtime.handle(.startMonitoring)
                }
                let server = try AgentServer(runtime: runtime,
                                            appExecutable: app.appendingPathComponent("Contents/MacOS/FlowQuota"))
                let listener = NSXPCListener(machServiceName: AgentEndpoint.machService)
                listener.delegate = server
                listener.resume()
                // Retain the weak delegate for the listener lifetime.
                activeListener = listener
                activeServer = server
            }
            termination.configure {
                // A signal during startup must not stop first and then start a new sampler.
                // Cancellation also interrupts diagnostic sampling sleeps without changing
                // successful --snapshot output or its normal cleanup path.
                startup.cancel()
                _ = await startup.result
                await runtime.stopRetentionMaintenance()
                defer {
                    activeListener?.invalidate()
                    activeListener = nil
                    activeServer = nil
                }
                _ = try await runtime.handle(.stopProtection)
            }
            do {
                try await startup.value
            } catch {
                if !termination.requested {
                    _ = try await runtime.handle(.stopProtection)
                    throw error
                }
            }
            if diagnostic, !termination.requested { return }
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        } catch {
            FileHandle.standardError.write(Data("FlowQuotaAgent: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func databasePath(diagnostic: Bool) throws -> URL {
        let arguments = CommandLine.arguments
        if diagnostic, let index = arguments.firstIndex(of: "--database"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("FlowQuota", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent("quota.sqlite")
    }
}
