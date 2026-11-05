import Testing
import UserNotifications
@testable import FlowQuotaApp

@MainActor @Test func feedbackKeepsFullErrorsAndDoesNotHideThemBehindSuccess() {
    let state = AppState(client: FakeAgentClient(), scheduler: FakeReminderScheduler())
    let error = String(repeating: "完整错误原因：保存未确认。", count: 80)
    state.reportNotice("此前操作已完成。")
    state.reportError(error)
    let presentation = ServiceFeedbackPresentation(state: state)
    #expect(presentation.hasError)
    #expect(presentation.title == "操作失败")
    #expect(presentation.entries.first?.detail == error)
    #expect(presentation.detail.contains("此前操作已完成"))
    state.clearMessages()
    let cleared = ServiceFeedbackPresentation(state: state)
    #expect(cleared.entries.isEmpty)
    #expect(cleared.title == "仅保存在本机")
}

@MainActor @Test func allServiceOperationsUseTheSameCompactFeedback() async {
    let state = AppState(client: FakeAgentClient(), scheduler: FakeReminderScheduler())
    for name in ["正在保存规则", "正在启用本地服务", "正在更新热点标记", "正在修复开发服务", "正在停止采集"] {
        state.perform(name) { state in state.reportNotice("服务已确认。") }
        #expect(ServiceFeedbackPresentation(state: state).working)
        #expect(ServiceFeedbackPresentation(state: state).title == name)
        await finishOperation(state)
        #expect(ServiceFeedbackPresentation(state: state).detail.contains("服务已确认"))
    }
}

@MainActor @Test func notificationRequestOfferDoesNotDependOnTransientReadingState() {
    #expect(NotificationPermission.offersRequest(for: .notDetermined))
    #expect(NotificationPermission.offersRequest(for: .provisional))
    #expect(!NotificationPermission.offersRequest(for: .authorized))
    #expect(!NotificationPermission.offersRequest(for: .denied))
    #expect(!NotificationPermission.offersRequest(for: nil))
}
