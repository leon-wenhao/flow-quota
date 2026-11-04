import FlowQuotaCore
import SwiftUI

struct QuotaEditor: View {
    let application: ApplicationSnapshot
    let state: AppState
    let done: @MainActor () -> Void
    @State private var limited: Bool
    @State private var amount: String
    @State private var unit: QuotaUnit
    @State private var warning: Int

    init(application: ApplicationSnapshot, state: AppState, done: @escaping @MainActor () -> Void) {
        self.application = application
        self.state = state
        self.done = done
        let limit = application.rule?.limitBytes
        let unit: QuotaUnit = (limit ?? 1_000_000_000) >= 1_000_000_000 ? .gigabytes : .megabytes
        _limited = State(initialValue: limit != nil)
        _unit = State(initialValue: unit)
        _amount = State(initialValue: limit.map { QuotaInput.text($0, unit: unit) } ?? "")
        _warning = State(initialValue: application.rule?.warningPercent ?? 80)
    }

    private var nextRule: QuotaRule? {
        let previous = application.rule?.version ?? 0
        guard previous < Int64.max else { return nil }
        let bytes = limited ? QuotaInput.bytes(amount, unit: unit) : nil
        guard !limited || bytes != nil else { return nil }
        return try? QuotaRule(limitBytes: bytes, warningPercent: warning, version: previous + 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(application.identity.name, systemImage: "app").font(.title3.bold())
            Text("今日已用 \(UsageFormatter.bytes(state.knownUsage(application)))")
                .font(.headline).monospacedDigit()
            Text("上传和下载均计入。只有服务确认接收后，新规则才会显示为已保存。")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Toggle("每日流量上限", isOn: $limited)
                if limited {
                    HStack(alignment: .firstTextBaseline) {
                        TextField("正数额度", text: $amount)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("每日流量上限数值")
                        Picker("单位", selection: $unit) {
                            ForEach(QuotaUnit.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .frame(width: 105)
                    }
                    Text("1 MB = 1,000,000 bytes；1 GB = 1,000,000,000 bytes。")
                        .font(.caption).foregroundStyle(.secondary)
                    if QuotaInput.bytes(amount, unit: unit) == nil {
                        Label("请输入正的十进制数，精确到整数 byte，且不超过 Int64 范围。", systemImage: "exclamationmark.circle")
                            .font(.caption)
                    }
                } else {
                    Text("不限额 · 仍会在保护组件就绪后计量热点用量。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper("接近上限时提醒：\(warning)%", value: $warning, in: 1...99)
                    .disabled(!limited)
                    .accessibilityValue("\(warning)%")
            }
            .disabled(!state.canEdit)
            if !state.canEdit {
                Label(state.unavailableReason, systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            Text("调低至今日用量及以下可触发阻断；调高后可允许后续重连。应用额度不等于运营商计费硬封顶。")
                .font(.caption).foregroundStyle(.secondary)
            if application.rule?.version == Int64.max {
                Label("规则版本已达上限，无法继续保存。", systemImage: "exclamationmark.triangle").font(.caption)
            }
            Button("保存额度", systemImage: "checkmark") {
                guard let rule = nextRule else { return }
                state.save(appKey: application.identity.key, rule: rule, acknowledged: done)
            }
            .buttonStyle(.borderedProminent)
            .disabled(nextRule == nil || !state.canEdit)
        }
    }
}
