import FlowQuotaCore
import SwiftUI

struct TrafficAlertSettingsView: View {
    let state: AppState
    let policy: TrafficAlertPolicy
    @State private var draft: TrafficAlertDraft

    init(state: AppState, policy: TrafficAlertPolicy) {
        self.state = state
        self.policy = policy
        _draft = State(initialValue: TrafficAlertDraft(policy))
    }

    var body: some View {
        DisclosureGroup("流量预警") {
            VStack(alignment: .leading, spacing: 14) {
                AlertThresholdInput(title: "接口每日总量", enabled: $draft.dailyEnabled, amount: $draft.dailyMB)
                AlertThresholdInput(title: "接口短时用量", enabled: $draft.interfaceEnabled, amount: $draft.interfaceMB)
                AlertThresholdInput(title: "应用／服务短时用量", enabled: $draft.applicationEnabled, amount: $draft.applicationMB)
                Stepper(value: $draft.windowMinutes, in: 1...15) {
                    Text("短时窗口：最多 \(draft.windowMinutes) 分钟")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Stepper(value: $draft.cooldownMinutes, in: 1...1440) {
                    Text("同来源提醒间隔：\(draft.cooldownMinutes) 分钟")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureGroup("预警规则") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("阈值为上传＋下载；1 MB = 1,000,000 bytes。短时预警可在窗口填满前触发，记录实际连续观测时长。")
                        Text("每日总量按配置版本提醒一次；短时预警按来源冷却。三类预警独立判断，应用／服务阈值分别用于每个来源，不相加、不从接口相减。")
                        Text("仅判断高成本网络或手动热点的连续观测区间。切网、跨日、暂停、重启、修改配置或采样间断后，短时窗口重新积累。")
                        Text("保存后仅发送提醒，不会阻断连接。")
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                .font(.caption).foregroundStyle(.secondary)
                if draft.policy == nil {
                    Label("启用项须为正数并精确到整数 byte，且不能超出整数范围。", systemImage: "exclamationmark.circle")
                        .font(.caption)
                }
                HStack {
                    Spacer()
                    Button("保存预警", systemImage: "checkmark") {
                        guard let policy = draft.policy else { return }
                        state.saveTrafficAlertPolicy(policy, acknowledged: {})
                    }
                    .settingsAction(prominent: true)
                    .disabled(!state.canEdit || draft.policy == nil)
                }
            }
            .padding(.top, 8).disabled(!state.canEdit)
        }
        .onChange(of: policy.version) { _, _ in draft = TrafficAlertDraft(policy) }
    }
}

private struct AlertThresholdInput: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var amount: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $enabled) {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch).controlSize(.small)
            .frame(maxWidth: .infinity)
            if enabled {
                HStack {
                    TextField("正数阈值", text: $amount).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(title)阈值（MB）")
                    Text("MB").foregroundStyle(.secondary)
                }
            }
        }
    }
}
