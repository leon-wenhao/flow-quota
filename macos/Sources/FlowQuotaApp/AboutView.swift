import SwiftUI

struct AboutView: View {
    let state: AppState
    private var updater: AppUpdater { state.updater }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            introduction
            SettingsSection(title: "项目与反馈") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    projectLink("GitHub", subtitle: "源码与项目主页", symbol: "chevron.left.forwardslash.chevron.right",
                                url: "https://github.com/leon-wenhao/flow-quota")
                    projectLink("Gitee", subtitle: "国内源码镜像", symbol: "point.3.connected.trianglepath.dotted",
                                url: "https://gitee.com/Leon-wh/flow-quota")
                    projectLink("反馈问题", subtitle: "报告问题与提出建议", symbol: "bubble.left.and.bubble.right",
                                url: "https://github.com/leon-wenhao/flow-quota/issues")
                    projectLink("版本发布", subtitle: "安装包与更新说明", symbol: "shippingbox",
                                url: "https://github.com/leon-wenhao/flow-quota/releases")
                }
            }
            SettingsSection(title: "开源与分发") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("MIT 开源许可", systemImage: "curlybraces")
                        Spacer()
                        Text("macOS 提醒版").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Label("当前为 ad-hoc 签名，未经 Apple 公证。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("统计数据保存在本机，仅保留当天；规则与偏好持续保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 18) {
                    FlowQuotaAppIcon().frame(width: 96, height: 96)
                    identity
                }
                VStack(alignment: .leading, spacing: 12) {
                    FlowQuotaAppIcon().frame(width: 80, height: 80)
                    identity
                }
            }
            Text("看清 Mac 的流量去向，在用量达到阈值时及时提醒。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 12) {
                Button("检查更新", systemImage: "arrow.triangle.2.circlepath") { updater.check() }
                    .settingsAction(prominent: true)
                    .disabled(!updater.canCheck || state.busy)
                Text(updater.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = updater.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let date = updater.lastCheck {
                Text("上次检查：\(date.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if updater.hasPendingInstall && !updater.installing {
                Button("重试安装") { updater.prepareInstallation() }
                    .settingsAction().disabled(state.busy)
            }
            if updater.needsRecovery && !updater.installing {
                HStack {
                    Button("恢复更新前的采集状态") {
                        Task { await updater.recover(allowStale: true) }
                    }.settingsAction()
                    Button("保持暂停并清除恢复标记") {
                        Task { await updater.recover(discard: true) }
                    }.settingsAction()
                }.disabled(state.busy)
            }
        }
        .flowQuotaCard(padding: 22)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flow Quota").font(.system(size: 28, weight: .bold, design: .rounded))
            Text(updater.currentVersion)
                .font(.subheadline.weight(.medium)).monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
    }

    private func projectLink(_ title: String, subtitle: String, symbol: String, url: String) -> some View {
        // Destinations are fixed public project URLs, never service- or user-supplied input.
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(FlowQuotaTheme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(FlowQuotaTheme.inputFill.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(FlowQuotaRowButtonStyle())
        .help(url)
    }
}
