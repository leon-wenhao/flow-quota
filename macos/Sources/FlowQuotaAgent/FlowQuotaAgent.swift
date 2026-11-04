import Darwin
import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import FlowQuotaStore

@main @MainActor struct FlowQuotaAgent {
    private static var activeListener: NSXPCListener?
    private static var activeServer: AgentServer?
    static func main() async {
        // SQLite sidecars and the database must be private to this local user.
        umask(0o077)
        do {
            let diagnostic = CommandLine.arguments.contains("--snapshot")
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let app = diagnostic ? nil : try PeerRequirement.containingApp(executable: executable)
            let path = try databasePath(diagnostic: diagnostic)
            try ServiceStorage.prepareDatabase(at: path)
            let store = try QuotaStore(path: path.path)
            let runtime = AgentRuntime(store: store)
            if diagnostic {
                let reply = try await runtime.handle(.snapshot)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(reply), as: UTF8.self))
                return
            }
            guard let app else { throw PlatformError.unavailable("缺少完整应用容器。") }
            let server = try AgentServer(runtime: runtime,
                                        appExecutable: app.appendingPathComponent("Contents/MacOS/FlowQuota"))
            let listener = NSXPCListener(machServiceName: AgentEndpoint.machService)
            listener.delegate = server
            listener.resume()
            // Retain the weak delegate and suspend without blocking an executor.
            activeListener = listener
            activeServer = server
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
