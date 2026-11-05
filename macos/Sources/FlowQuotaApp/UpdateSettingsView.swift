import AppKit
import SwiftUI

struct UpdateSettingsView: View {
    let state: AppState

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
                    .disabled(state.updateChecking)
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
                        Button("打开下载页") { NSWorkspace.shared.open(release.downloadURL) }
                            .settingsAction()
                        if let notesURL = release.releaseNotesURL {
                            Button("查看更新说明") { NSWorkspace.shared.open(notesURL) }
                                .settingsAction()
                        }
                    }
                }
                Text("当前版本只检查并打开下载页面，不会自动替换应用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
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
