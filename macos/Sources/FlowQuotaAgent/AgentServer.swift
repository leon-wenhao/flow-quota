import Foundation
import FlowQuotaCore
import FlowQuotaPlatform

/// NSXPC invokes this delegate on its own queue; shared mutable state lives in
/// AgentRuntime's actor and all per-connection setup is synchronous.
final class AgentServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let runtime: AgentRuntime
    private let expectedClient: String

    init(runtime: AgentRuntime, appExecutable: URL) throws {
        self.runtime = runtime
        self.expectedClient = try PeerRequirement.string(forExecutable: appExecutable)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(expectedClient)
        connection.exportedInterface = NSXPCInterface(with: AgentXPCProtocol.self)
        connection.exportedObject = AgentHandler(runtime: runtime)
        connection.resume()
        return true
    }
}

private final class AgentHandler: NSObject, AgentXPCProtocol, @unchecked Sendable {
    private let runtime: AgentRuntime

    init(runtime: AgentRuntime) { self.runtime = runtime }

    func perform(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard request.count <= AgentEndpoint.maximumMessageBytes else {
            reply(nil, "请求超过本地协议大小限制。")
            return
        }
        let runtime = runtime
        Task {
            do {
                let command = try JSONDecoder().decode(AgentRequest.self, from: request)
                let result = try await runtime.handle(command)
                let payload = try JSONEncoder().encode(result)
                guard payload.count <= AgentEndpoint.maximumMessageBytes else {
                    throw PlatformError.unavailable("应用列表超过协议容量，不能显示完整用量。")
                }
                reply(payload, nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }
}
