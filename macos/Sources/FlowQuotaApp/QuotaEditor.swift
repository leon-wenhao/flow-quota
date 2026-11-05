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

    private var source: SystemProcessClassification { SystemProcessClassification(identity: application.identity) }
    private var sourceType: String {
        switch source.category {
        case .sharedProxy: "共享代理服务"
        case .sharedDownload: "共享下载服务"
        case .wallpaper: "系统组件"
        case .application: "应用"
        case .unconfirmed: "监测来源"
        }
    }
    private var sharedSource: Bool { source.category == .sharedDownload || source.category == .sharedProxy }
    private var nextRule: QuotaRule? {
        let previous = application.rule?.version ?? 0
        guard previous < Int64.max else { return nil }
        let bytes = limited ? QuotaInput.bytes(amount, unit: unit) : nil
        guard !limited || bytes != nil else { return nil }
        return try? QuotaRule(limitBytes: bytes, warningPercent: warning, version: previous + 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            usageSummary
            reminderSettings
            sourceDetails
        }
    }

    private var usageSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ApplicationSourceMark(name: source.displayName, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.displayName).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(sourceType).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("今日应用归因")
                    Spacer()
                    Text("上传＋下载")
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(UsageFormatter.bytes(state.knownUsage(application)))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .accessibilityLabel("今日应用归因用量：\(UsageFormatter.bytes(state.knownUsage(application)))")
                if sharedSource {
                    Label("共享服务 · 原始请求方未确认", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var reminderSettings: some View {
        SettingsSection(title: "每日提醒") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $limited) {
                    Text("启用每日阈值").frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch).controlSize(.small)
                if limited {
                    HStack(spacing: 8) {
                        TextField("输入阈值", text: $amount)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("每日提醒阈值数值")
                        Picker("单位", selection: $unit) {
                            ForEach(QuotaUnit.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 80).accessibilityLabel("阈值单位")
                    }
                    Stepper(value: $warning, in: 1...99) {
                        Text("提前提醒：\(warning)%").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.subheadline).accessibilityValue("\(warning)%")
                    if QuotaInput.bytes(amount, unit: unit) == nil {
                        Label("请输入有效的正数阈值。", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                            .help("须精确到整数 byte，且不能超出 Int64 范围。")
                    }
                } else {
                    Text("未设阈值，仍统计用量。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!state.canEdit)
            Divider()
            HStack(spacing: 8) {
                // Busy/ACK states replace this fixed slot instead of inserting a lock row.
                Text(state.canEdit ? "仅提醒，不阻断" : state.unavailableReason)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
                    .help(state.canEdit ? "保存后仅更新此来源的每日提醒配置。" : state.unavailableReason)
                Button("保存设置", systemImage: "checkmark") {
                    guard let rule = nextRule else { return }
                    state.save(appKey: application.identity.key, rule: rule, acknowledged: done)
                }
                .settingsAction(prominent: true).fixedSize()
                .disabled(nextRule == nil || !state.canEdit)
            }
            if application.rule?.version == Int64.max {
                Label("配置版本已达上限，无法保存。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var sourceDetails: some View {
        SettingsSection(title: "更多信息") {
            DisclosureGroup("来源与身份") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(source.detail)
                    Text(application.identity.name)
                    Text(application.identity.key).font(.caption2)
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 4)
            }
            Divider()
            DisclosureGroup("计量说明") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("高成本网络与手动热点共用此来源的每日提醒预算。按该来源归因用量提醒，可能与代理重叠，不与接口总量相加。")
                    Text("仅含服务运行期间观测的上传＋下载，不代表完整自然日用量或运营商账单；未知期间不回填。")
                    Text("1 MB = 1,000,000 bytes；1 GB = 1,000,000,000 bytes。阈值须为正数、精确到整数 byte，且不能超出 Int64 范围。")
                    Text("达到阈值只发送提醒；保存成功仅表示配置已持久化。")
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 4)
            }
            .font(.subheadline)
        }
    }
}
