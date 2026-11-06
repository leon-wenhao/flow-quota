import Foundation
import ServiceManagement
import Testing
@testable import FlowQuotaPlatform

@MainActor
struct AgentConnectionRecoveryTests {
    @Test func enabledOldHelperIsReplacedBeforeStarting() async throws {
        let service = Service()
        service.probeErrors = [.connectionFailed("old cdhash rejected")]
        try await service.recovery.connect(startMonitoring: true)
        #expect(service.events == ["probe", "unregister", "refresh-app", "register", "probe", "start"])
    }

    @Test func timedOutOldHelperIsAlsoRecovered() async throws {
        let service = Service()
        service.probeErrors = [.timeout]
        try await service.recovery.connect(startMonitoring: true)
        #expect(service.events == ["probe", "unregister", "refresh-app", "register", "probe", "start"])
    }

    @Test func healthyHelperKeepsItsProcessAndBaselines() async throws {
        let service = Service()
        try await service.recovery.connect(startMonitoring: true)
        #expect(service.events == ["probe", "start"])
    }

    @Test func freshInstallationRegistersAndVerifiesBeforeStarting() async throws {
        let service = Service(status: .notRegistered)
        try await service.recovery.connect(startMonitoring: true)
        #expect(service.events == ["refresh-app", "register", "probe", "start"])
    }

    @Test func approvalIsNeverBypassedByReregistration() async throws {
        let service = Service(status: .requiresApproval)
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: true)
        }
        #expect(service.events.isEmpty)
    }

    @Test func registrationRequiringApprovalDoesNotProbeOrStart() async throws {
        let service = Service(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: true)
        }
        #expect(service.events == ["refresh-app", "register"])
    }

    @Test func revokedApprovalDuringFailedProbeDoesNotRestart() async throws {
        let service = Service()
        service.probeErrors = [.connectionFailed("disabled by user")]
        service.onProbe = { service.status = .requiresApproval }
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: true)
        }
        #expect(service.events == ["probe"])
    }

    @Test func persistentFailureOnlyReplacesOnceAndStaysVisible() async throws {
        let service = Service()
        service.probeErrors = [.connectionFailed("old cdhash"), .connectionFailed("new cdhash rejected")]
        do {
            try await service.recovery.connect(startMonitoring: true)
            Issue.record("A failed replacement must not report connection success")
        } catch {
            #expect(error.localizedDescription.contains("仍无法连接"))
            #expect(error.localizedDescription.contains("new cdhash rejected"))
        }
        #expect(service.events == ["probe", "unregister", "refresh-app", "register", "probe"])
    }

    @Test func businessAndProtocolErrorsNeverReplaceService() async throws {
        for error in [PlatformError.unavailable("database unavailable"), .malformedReply] {
            let service = Service()
            service.probeErrors = [error]
            await #expect(throws: PlatformError.self) {
                try await service.recovery.connect(startMonitoring: true)
            }
            #expect(service.events == ["probe"])
        }
    }

    @Test func uncertainStartAcknowledgementDoesNotRestartOrRetry() async throws {
        let service = Service()
        service.startError = PlatformError.connectionFailed("ACK lost")
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: true)
        }
        #expect(service.events == ["probe", "start"])
    }

    @Test func buildsWithProtectionCannotAutomaticallyReplace() async throws {
        let service = Service()
        service.allowsReplacement = false
        service.probeErrors = [.connectionFailed("identity changed")]
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: true)
        }
        #expect(service.events == ["probe"])
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: true, replacingRegistration: true)
        }
        #expect(service.events == ["probe"])
    }

    @Test func unregisterFailureDoesNotRegisterOrStart() async throws {
        let service = Service()
        service.probeErrors = [.timeout]
        service.unregisterError = PlatformError.unavailable("unregister failed")
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: true)
        }
        #expect(service.events == ["probe", "unregister"])
    }

    @Test func registerFailureAfterUnregisterStaysVisible() async throws {
        let service = Service()
        service.probeErrors = [.timeout]
        service.registerError = PlatformError.unavailable("register failed")
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: true)
        }
        #expect(service.events == ["probe", "unregister", "refresh-app", "register"])
    }

    @Test func refreshFailureDoesNotRegisterProbeOrStart() async throws {
        let service = Service(status: .notRegistered)
        service.refreshError = PlatformError.unavailable("LaunchServices failed")
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: true)
        }
        #expect(service.events == ["refresh-app"])
    }

    @Test func refreshFailureAfterUnregisterRemainsVisible() async throws {
        let service = Service()
        service.probeErrors = [.timeout]
        service.refreshError = PlatformError.unavailable("LaunchServices failed")
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: false)
        }
        #expect(service.events == ["probe", "unregister", "refresh-app"])
        #expect(service.status == .notRegistered)
    }

    @Test func approvalRevokedDuringRefreshDoesNotRegister() async throws {
        let service = Service(status: .notRegistered)
        service.onRefresh = { service.status = .requiresApproval }
        await #expect(throws: PlatformError.self) {
            try await service.recovery.connect(startMonitoring: true)
        }
        #expect(service.events == ["refresh-app"])
    }

    @Test func successiveUpdatesRefreshEachNewRegistration() async throws {
        let service = Service(status: .notRegistered)
        for _ in 0..<3 {
            service.events.removeAll()
            try await service.recovery.connect(startMonitoring: false)
            #expect(service.events == ["refresh-app", "register", "probe"])
            service.status = .notRegistered
        }
    }

    @Test func cancelledProbeDoesNotRepair() async throws {
        let service = Service()
        service.probeCancellation = true
        await #expect(throws: CancellationError.self) {
            try await service.recovery.connect(startMonitoring: true)
        }
        #expect(service.events == ["probe"])
    }

    @Test func cancellationWhileUnregisteringCompletesRegistrationWithoutStarting() async throws {
        let service = Service()
        service.probeErrors = [.timeout]
        service.onUnregister = { withUnsafeCurrentTask { $0?.cancel() } }
        let connecting = Task { try await service.recovery.connect(startMonitoring: true) }
        await #expect(throws: CancellationError.self) { try await connecting.value }
        #expect(service.events == ["probe", "unregister", "refresh-app", "register"])
        #expect(service.status == .enabled)
    }

    @Test func explicitPausedRepairVerifiesWithoutStarting() async throws {
        let service = Service()
        try await service.recovery.connect(startMonitoring: false, replacingRegistration: true)
        #expect(service.events == ["unregister", "refresh-app", "register", "probe"])
    }

    @Test func repeatedConnectionAfterRecoveryDoesNotReplaceAgain() async throws {
        let service = Service()
        service.probeErrors = [.timeout]
        try await service.recovery.connect(startMonitoring: true)
        service.events.removeAll()
        try await service.recovery.connect(startMonitoring: true)
        #expect(service.events == ["probe", "start"])
    }
}

@MainActor
private final class Service {
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status = .enabled
    var events: [String] = []
    var probeErrors: [PlatformError] = []
    var probeCancellation = false
    var refreshError: (any Error)?
    var onRefresh: (() -> Void)?
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    var startError: (any Error)?
    var allowsReplacement = true
    var onProbe: (() -> Void)?
    var onUnregister: (() -> Void)?

    init(status: SMAppService.Status = .enabled) { self.status = status }

    var recovery: AgentConnectionRecovery {
        AgentConnectionRecovery(status: { self.status }, refreshApplication: {
            self.events.append("refresh-app")
            if let error = self.refreshError { throw error }
            self.onRefresh?()
        }, register: {
            self.events.append("register")
            if let error = self.registerError { throw error }
            self.status = self.statusAfterRegister
        }, unregister: {
            self.events.append("unregister")
            if let error = self.unregisterError { throw error }
            self.onUnregister?()
            self.status = .notRegistered
        }, verifyConnection: {
            self.events.append("probe")
            self.onProbe?()
            if self.probeCancellation { throw CancellationError() }
            if !self.probeErrors.isEmpty { throw self.probeErrors.removeFirst() }
        }, startMonitoring: {
            self.events.append("start")
            if let error = self.startError { throw error }
        }, allowsReplacement: allowsReplacement)
    }
}
