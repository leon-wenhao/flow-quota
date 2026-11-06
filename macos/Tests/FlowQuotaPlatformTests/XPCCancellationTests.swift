import Foundation
import Testing
@testable import FlowQuotaPlatform

@Test func cancellationBeforeContinuationInstallIsDelivered() async {
    let connection = NSXPCConnection(serviceName: "local.flowquota.test.unused")
    let completion = XPCCompletion(connection: connection)
    completion.cancel()
    do {
        let _: Data = try await withCheckedThrowingContinuation { continuation in
            #expect(!completion.install(continuation))
        }
        Issue.record("An early cancellation must fail the awaiting request")
    } catch { #expect(error is CancellationError) }
}

@Test func racingReplyErrorAndCancellationResolveExactlyOnce() async {
    let connection = NSXPCConnection(serviceName: "local.flowquota.test.unused")
    let completion = XPCCompletion(connection: connection)
    let awaiting = Task {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            _ = completion.install(continuation)
        }
    }
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<96 {
            group.addTask {
                switch index % 3 {
                case 0: completion.succeed(Data([42]))
                case 1: completion.fail("connection ended")
                default: completion.cancel()
                }
            }
        }
    }
    switch await awaiting.result {
    case .success(let data): #expect(data == Data([42]))
    case .failure(let error): #expect(error is CancellationError || error is PlatformError)
    }
}

@Test func transportAndAgentErrorsRemainDistinct() async {
    for transport in [false, true] {
        let connection = NSXPCConnection(serviceName: "local.flowquota.test.unused")
        let completion = XPCCompletion(connection: connection)
        if transport { completion.failConnection("identity rejected") }
        else { completion.fail("database unavailable") }
        do {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                #expect(!completion.install(continuation))
            }
            Issue.record("An error must fail the awaiting request")
        } catch {
            guard let error = error as? PlatformError else {
                Issue.record("Unexpected error: \(error)")
                continue
            }
            switch error {
            case .connectionFailed: #expect(transport)
            case .unavailable: #expect(!transport)
            default: Issue.record("Unexpected failure kind: \(error)")
            }
        }
    }
}
