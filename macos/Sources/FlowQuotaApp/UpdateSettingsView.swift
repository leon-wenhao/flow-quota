import SwiftUI

/// The automatic update preference stays in General Settings. Manual checks and
/// their result details live on the About page.
struct UpdateSettingsView: View {
    let state: AppState
    private var updater: AppUpdater { state.updater }

    var body: some View {
        SettingsSection(title: "软件更新") {
            HStack(spacing: 12) {
                Text("自动检查新版本")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("自动检查新版本", isOn: Binding(
                    get: { updater.automaticChecks.enabled },
                    set: { updater.automaticChecks.setEnabled($0) }))
                    .labelsHidden().toggleStyle(FlowQuotaToggleStyle()).fixedSize()
            }
            .padding(.vertical, 3)
        }
    }
}
