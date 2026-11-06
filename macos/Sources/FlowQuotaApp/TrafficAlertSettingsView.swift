import FlowQuotaCore
import SwiftUI

struct TrafficAlertSettingsView: View {
    let state: AppState
    let category: TrafficCategory
    let policy: TrafficAlertPolicy
    @State private var draft: TrafficAlertDraft

    init(state: AppState, policy: TrafficAlertPolicy) {
        self.category = state.selectedTrafficCategory
        self.state = state
        self.policy = policy
        _draft = State(initialValue: TrafficAlertDraft(policy))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "用量阈值") {
                VStack(spacing: 14) {
                    AlertThresholdInput(title: "接口每日总量", enabled: $draft.dailyEnabled, amount: $draft.dailyMB)
                    Divider()
                    AlertThresholdInput(title: "接口短时用量", enabled: $draft.interfaceEnabled, amount: $draft.interfaceMB)
                    Divider()
                    AlertThresholdInput(title: "应用／服务短时用量", enabled: $draft.applicationEnabled, amount: $draft.applicationMB)
                }
            }
            SettingsSection(title: "短时规则") {
                VStack(spacing: 14) {
                    FlowQuotaStepper(title: "短时窗口", suffix: "分钟", value: $draft.windowMinutes,
                        range: 1...15, layout: .inline)
                    Divider()
                    FlowQuotaStepper(title: "同来源提醒间隔", suffix: "分钟", value: $draft.cooldownMinutes,
                        range: 1...1440, layout: .inline)
                }
            }
            if draft.policy == nil {
                Label("启用项须为正数并精确到整数 byte，且不能超出整数范围。", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button("保存预警", systemImage: "checkmark") {
                guard let policy = draft.policy else { return }
                state.saveTrafficAlertPolicy(policy, category: category, acknowledged: {})
            }
            .settingsAction(prominent: true)
            .disabled(!state.canEdit || draft.policy == nil)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .disabled(!state.canEdit)
        .onChange(of: policy.version) { _, _ in draft = TrafficAlertDraft(policy) }
    }
}

/// Keeping the input mounted while disabled preserves both its draft and row height.
private struct AlertThresholdInput: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var amount: String

    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                TextField("阈值", text: $amount)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .accessibilityLabel("\(title)阈值（MB）")
                Text("MB").font(.caption).foregroundStyle(.secondary)
            }
            .flowQuotaControl()
            .frame(width: 136)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.42)
            Toggle(title, isOn: $enabled)
                .labelsHidden().toggleStyle(FlowQuotaToggleStyle()).fixedSize()
        }
        .frame(minHeight: FlowQuotaTheme.controlHeight)
    }
}
