import FlowQuotaCore
import SwiftUI

struct QuotaEditor: View {
    let category: TrafficCategory
    let application: ApplicationSnapshot
    let state: AppState
    let done: @MainActor () -> Void
    @State private var limited: Bool
    @State private var amount: String
    @State private var unit: QuotaUnit
    @State private var warning: Int

    init(application: ApplicationSnapshot, state: AppState, done: @escaping @MainActor () -> Void) {
        self.category = state.selectedTrafficCategory
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
            Text("\(category.title) · 应用每日提醒").font(.caption).foregroundStyle(.secondary)
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
                Text(UsageFormatter.bytes(state.knownUsage(application, category: category)))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .accessibilityLabel("今日应用归因用量：\(UsageFormatter.bytes(state.knownUsage(application, category: category)))")
                if sharedSource {
                    Label("共享服务 · 原始请求方未确认", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowQuotaCard(padding: 14)
    }

    private var reminderSettings: some View {
        SettingsSection(title: "每日提醒") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("启用每日阈值").frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("启用每日阈值", isOn: $limited)
                        .labelsHidden().toggleStyle(FlowQuotaToggleStyle()).fixedSize()
                }
                if limited {
                    HStack(spacing: 8) {
                        TextField("输入阈值", text: $amount)
                            .textFieldStyle(.plain)
                            .flowQuotaControl()
                            .accessibilityLabel("每日提醒阈值数值")
                        FlowQuotaSegmentedControl(options: QuotaUnit.allCases, selection: $unit,
                            title: { $0.rawValue }, accessibilityLabel: "阈值单位")
                            .frame(width: 112)
                    }
                    FlowQuotaStepper(title: "提前提醒", suffix: "%", value: $warning, range: 1...99)
                    if QuotaInput.bytes(amount, unit: unit) == nil {
                        Label("请输入有效的正数阈值。", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                            .help("须精确到整数 byte，且不能超出 Int64 范围。")
                    }
                }
            }
            .disabled(!state.canEdit)
            HStack(spacing: 8) {
                // Busy/ACK states replace this fixed slot instead of inserting a lock row.
                Text(state.canEdit ? "" : state.unavailableReason)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
                    .help(state.canEdit ? "保存后仅更新此来源的每日提醒配置。" : state.unavailableReason)
                Button("保存设置", systemImage: "checkmark") {
                    guard let rule = nextRule else { return }
                    state.save(appKey: application.identity.key, rule: rule, category: category, acknowledged: done)
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
            .font(.subheadline)
        }
    }
}
