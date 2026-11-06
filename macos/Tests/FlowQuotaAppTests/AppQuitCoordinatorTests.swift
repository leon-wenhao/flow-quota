import AppKit
import CoreServices
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

@MainActor struct AppQuitCoordinatorTests {
    @Test func quitKeepsEventLoopRunningUntilStopCompletes() async {
        let context = QuitContext()
        context.client.holdStop = true
        #expect(context.coordinator.request() == .terminateCancel)
        #expect(context.coordinator.stopping)
        #expect(context.state.quitRequested)
        #expect(context.state.busy)
        #expect(context.events == ["suspend", "show"])
        await context.waitForStop()
        #expect(!context.coordinator.readyToTerminate)
        #expect(context.promptCount == 0)
        context.client.stopGate?.resume()
        await context.waitForCompletion()
        #expect(context.coordinator.readyToTerminate)
        #expect(context.coordinator.request() == .terminateNow)
        #expect(context.events == ["suspend", "show", "hide", "terminate"])
        #expect(!context.completedWhileBusy)
    }

    @Test func systemQuitRepliesAfterStopWithoutCancellingShutdown() async {
        let context = QuitContext()
        context.client.holdStop = true
        var reply: Bool?
        #expect(context.coordinator.request(systemReply: { reply = $0 }) == .terminateLater)
        await context.waitForStop()
        #expect(reply == nil)
        #expect(context.coordinator.request() == .terminateLater)
        context.client.stopGate?.resume()
        await context.waitForCompletion()
        #expect(reply == true)
        #expect(!context.events.contains("terminate"))
    }

    @Test func shutdownDuringOrdinaryQuitAdoptsDeferredReply() async {
        let context = QuitContext()
        context.client.holdStop = true
        #expect(context.coordinator.request() == .terminateCancel)
        await context.waitForStop()
        var reply: Bool?
        #expect(context.coordinator.request(systemReply: { reply = $0 }) == .terminateLater)
        context.client.stopGate?.resume()
        await context.waitForCompletion()
        #expect(reply == true)
        #expect(context.client.stoppedCount == 1)
        #expect(!context.events.contains("terminate"))
    }

    @Test func failedSystemQuitRepliesWithCancellation() async {
        let context = QuitContext()
        context.client.stopFails = true
        var reply: Bool?
        #expect(context.coordinator.request(systemReply: { reply = $0 }) == .terminateLater)
        await context.waitForCompletion()
        #expect(reply == false)
        #expect(!context.coordinator.readyToTerminate)
        #expect(context.events.last == "resume")
    }

    @Test(arguments: [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut])
    func systemAppleEventsPreserveTerminationReason(_ reason: OSType) {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        #expect(!AppQuitCoordinator.needsSystemReply(for: nil))
        #expect(!AppQuitCoordinator.needsSystemReply(for: event))
        event.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: AEKeyword(kAEQuitReason))
        #expect(AppQuitCoordinator.needsSystemReply(for: event))
    }

    @Test func repeatedQuitOnlyRaisesProgressWindow() async {
        let context = QuitContext()
        context.client.holdStop = true
        #expect(context.coordinator.request() == .terminateCancel)
        await context.waitForStop()
        #expect(context.coordinator.request() == .terminateCancel)
        #expect(context.client.stoppedCount == 1)
        #expect(context.events == ["suspend", "show", "show"])
        context.client.stopGate?.resume()
        await context.waitForCompletion()
    }

    @Test func failedStopResumesPollingWhenUserReturns() async {
        let context = QuitContext()
        context.client.stopFails = true
        #expect(context.coordinator.request() == .terminateCancel)
        await context.waitForCompletion()
        #expect(!context.coordinator.readyToTerminate)
        #expect(!context.state.quitRequested)
        #expect(context.promptCount == 1)
        #expect(context.events == ["suspend", "show", "hide", "confirm", "resume"])
        #expect(!context.completedWhileBusy)
        context.client.stopFails = false
        #expect(context.coordinator.request() == .terminateCancel)
        await context.waitForCompletion()
        #expect(context.coordinator.readyToTerminate)
    }

    @Test func quitDuringFailurePromptDoesNotStartAnotherStop() async {
        let context = QuitContext()
        context.client.stopFails = true
        context.requestDuringFailure = true
        #expect(context.coordinator.request() == .terminateCancel)
        await context.waitForCompletion()
        #expect(context.client.stoppedCount == 1)
        #expect(context.promptCount == 1)
        #expect(context.events == ["suspend", "show", "hide", "confirm", "resume"])
    }

    @Test func UIOnlyExitRequiresExplicitChoice() async {
        let context = QuitContext()
        context.client.stopFails = true
        context.acceptUIExit = true
        #expect(context.coordinator.request() == .terminateCancel)
        await context.waitForCompletion()
        #expect(context.coordinator.readyToTerminate)
        #expect(context.promptCount == 1)
        #expect(context.events == ["suspend", "show", "hide", "confirm", "terminate"])
    }

    @Test func recoveryProgressRemainsVisibleUntilConfirmed() async {
        let context = QuitContext()
        context.client.holdStop = true
        context.client.recoveringStop = true
        #expect(context.coordinator.request() == .terminateCancel)
        await context.waitForStop()
        #expect(context.state.operation == "服务未响应，正在停止后台服务")
        #expect(context.state.quitRequested)
        #expect(!context.coordinator.readyToTerminate)
        context.client.stopGate?.resume()
        await context.waitForCompletion()
        #expect(context.coordinator.readyToTerminate)
        #expect(context.promptCount == 0)
    }

    @Test func otherMutationIsNotInterruptedByQuit() async {
        let context = QuitContext()
        context.client.holdAlertPolicySave = true
        context.state.perform("正在保存配置") { state in
            try await context.client.saveTrafficAlertPolicy(.initial)
            state.reportNotice("已保存")
        }
        #expect(context.coordinator.request() == .terminateCancel)
        #expect(context.events.isEmpty)
        #expect(!context.state.quitRequested)
        #expect(context.client.stoppedCount == 0)
        let deadline = ContinuousClock.now + .seconds(2)
        while context.client.alertPolicySaveGate == nil && ContinuousClock.now < deadline { await Task.yield() }
        context.client.alertPolicySaveGate?.resume()
        await finishOperation(context.state)
    }
}

@MainActor private final class QuitContext {
    let client = FakeAgentClient()
    lazy var state = AppState(client: client)
    var events: [String] = []
    var acceptUIExit = false
    var requestDuringFailure = false
    var promptCount = 0
    var completedWhileBusy = false
    lazy var coordinator: AppQuitCoordinator = AppQuitCoordinator(state: state,
        suspendPolling: { self.events.append("suspend") },
        resumePolling: { self.events.append("resume") },
        showProgress: { self.events.append("show") },
        hideProgress: { self.events.append("hide"); self.completedWhileBusy = self.state.busy },
        confirmUIExit: { message in
            #expect(!message.isEmpty)
            self.promptCount += 1
            self.events.append("confirm")
            if self.requestDuringFailure { #expect(self.coordinator.request() == .terminateCancel) }
            return self.acceptUIExit
        }, terminate: { self.events.append("terminate") })

    func waitForStop() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while client.stopGate == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(client.stopGate != nil)
    }

    func waitForCompletion() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while coordinator.stopping && ContinuousClock.now < deadline { await Task.yield() }
        #expect(!coordinator.stopping)
        #expect(!state.busy)
    }
}
