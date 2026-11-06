import AppKit
import SwiftUI

struct UpdateSettingsView: View {
    let state: AppState
    @State private var showInstallInstructions = false

    var body: some View {
        SettingsSection(title: "软件更新") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前版本")
                        Text(state.currentVersionText)
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Button("检查更新", systemImage: "arrow.triangle.2.circlepath") {
                        state.checkForUpdates()
                    }
                    .settingsAction()
                    .disabled(state.updateChecking || state.busy)
                }
                Text(state.updateState.message)
                    .font(.caption)
                    .foregroundStyle(stateColor)
                    .textSelection(.enabled)
                if let checkedAt = state.lastUpdateCheckAt {
                    Text("上次检查：\(checkedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if case .available(let release) = state.updateState {
                    HStack(spacing: 10) {
                        if release.package != nil {
                            Button("下载并安装") {
                                state.downloadAndInstall(release)
                            }
                            .settingsAction()
                            .disabled(state.busy)
                        } else {
                            Button("打开下载页") { NSWorkspace.shared.open(release.downloadURL) }
                                .settingsAction()
                        }
                        if let notesURL = release.releaseNotesURL {
                            Button("查看更新说明") { NSWorkspace.shared.open(notesURL) }
                                .settingsAction()
                        }
                    }
                }
            }
            .padding(.top, 2)
            .onChange(of: state.downloadedUpdateURL) { _, newValue in
                if newValue != nil { showInstallInstructions = true }
            }
            .alert("更新包已打开", isPresented: $showInstallInstructions) {
                Button("打开 Applications 文件夹") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
                }
                Button("知道了", role: .cancel) {}
            } message: {
                Text("请将 Flow Quota.app 拖到右侧的 Applications 文件夹，然后从 Applications 打开。首次打开若被系统拦截，请到系统设置 → 隐私与安全性中选择“仍要打开”。")
            }
        }
    }

    private var stateColor: Color {
        switch state.updateState {
        case .available: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}
