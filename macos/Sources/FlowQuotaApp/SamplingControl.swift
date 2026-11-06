import SwiftUI

/// Shared by overview and details/settings. Only confirmed service state is a
/// switch; connecting to an unavailable or older service remains an explicit action.
struct SamplingControl: View {
    let state: AppState

    var body: some View {
        Group {
            if let enabled = state.samplingEnabled {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { state.setSamplingEnabled($0) }
                )) { Text("流量采集") }
                .labelsHidden().toggleStyle(FlowQuotaToggleStyle()).fixedSize()
                .disabled(!state.canChangeSampling)
                .help("开启或暂停接口与应用采集；仅累计已观测流量，暂停不清空今日用量。")
            } else {
                Button("连接服务") { state.enableAgent() }
                    .settingsAction()
                    .disabled(state.busy || state.quitRequested)
                    .help("采集状态未知；连接服务并请求启用采集，以返回状态为准。")
            }
        }
    }
}
