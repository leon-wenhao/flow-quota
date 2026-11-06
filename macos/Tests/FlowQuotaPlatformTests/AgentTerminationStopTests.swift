import Foundation
import ServiceManagement
import Testing
@testable import FlowQuotaPlatform

@MainActor struct AgentTerminationStopTests {
    @Test func removedServiceNeedsNoRequest() async throws {
        let service = StopService()
        service.status = .notRegistered
        try await service.operation.run(onRecovery: service.recover)
        #expect(service.events.isEmpty)
    }

    @Test func healthyStopDoesNotRemoveService() async throws {
        let service = StopService()
        try await service.operation.run(onRecovery: service.recover)
        #expect(service.events == ["stop"])
    }

    @Test(arguments: [PlatformError.timeout, .connectionFailed("disconnected")])
    func transportFailureWaitsForRemoval(_ error: PlatformError) async throws {
        let service = StopService()
        service.stopError = error
        service.holdRemoval = true
        var finished = false
        let task = Task { @MainActor in
            try await service.operation.run(onRecovery: service.recover)
            finished = true
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while service.removalGate == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(service.removalGate != nil)
        #expect(!finished)
        #expect(service.events == ["stop", "recovery", "unregister"])
        service.removalGate?.resume()
        try await task.value
        #expect(finished)
        #expect(service.status == .notRegistered)
    }

    @Test(arguments: [PlatformError.unavailable("agent rejected stop"), .malformedReply])
    func serviceErrorsDoNotRemoveService(_ error: PlatformError) async {
        let service = StopService()
        service.stopError = error
        await #expect(throws: (any Error).self) {
            try await service.operation.run(onRecovery: service.recover)
        }
        #expect(service.events == ["stop"])
    }

    @Test func filteringBuildDoesNotUseReminderFallback() async {
        let service = StopService()
        service.stopError = PlatformError.timeout
        service.allowsUnregister = false
        await #expect(throws: (any Error).self) {
            try await service.operation.run(onRecovery: service.recover)
        }
        #expect(service.events == ["stop"])
    }

    @Test func cancellationDoesNotRemoveService() async {
        let service = StopService()
        service.stopError = CancellationError()
        await #expect(throws: CancellationError.self) {
            try await service.operation.run(onRecovery: service.recover)
        }
        #expect(service.events == ["stop"])
    }

    @Test func removalFailurePreservesBothErrors() async {
        let service = StopService()
        service.stopError = PlatformError.connectionFailed("original transport failure")
        service.removalError = PlatformError.unavailable("removal denied")
        do {
            try await service.operation.run(onRecovery: service.recover)
            Issue.record("Unconfirmed removal must not permit quitting")
        } catch {
            #expect(error.localizedDescription.contains("original transport failure"))
            #expect(error.localizedDescription.contains("removal denied"))
        }
    }

    @Test func removalCallbackAloneIsNotConfirmation() async {
        let service = StopService()
        service.stopError = PlatformError.timeout
        service.removesRegistration = false
        await #expect(throws: (any Error).self) {
            try await service.operation.run(onRecovery: service.recover)
        }
        #expect(service.status == .enabled)
    }
}

@MainActor private final class StopService {
    var status: SMAppService.Status = .enabled
    var stopError: (any Error)?
    var removalError: (any Error)?
    var allowsUnregister = true
    var removesRegistration = true
    var holdRemoval = false
    var removalGate: CheckedContinuation<Void, Never>?
    var events: [String] = []

    var operation: AgentTerminationStop {
        AgentTerminationStop(status: { self.status }, stop: {
            self.events.append("stop")
            if let error = self.stopError { throw error }
        }, unregister: {
            self.events.append("unregister")
            if self.holdRemoval { await withCheckedContinuation { self.removalGate = $0 } }
            if let error = self.removalError { throw error }
            if self.removesRegistration { self.status = .notRegistered }
        }, allowsUnregister: allowsUnregister)
    }

    func recover() { events.append("recovery") }
}
