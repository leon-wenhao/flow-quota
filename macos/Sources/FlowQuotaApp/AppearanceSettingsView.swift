import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppAppearancePreference.key) private var storedAppearance = AppAppearancePreference.system.rawValue

    private var selection: Binding<AppAppearancePreference> {
        Binding(
            get: { AppAppearancePreference(rawValue: storedAppearance) ?? .system },
            set: {
                storedAppearance = $0.rawValue
                $0.apply()
            }
        )
    }

    var body: some View {
        HStack(spacing: 16) {
            Text("外观").frame(maxWidth: .infinity, alignment: .leading)
            FlowQuotaSegmentedControl(
                options: AppAppearancePreference.allCases,
                selection: selection,
                title: { $0.title },
                accessibilityLabel: "应用外观"
            )
            .frame(width: 284)
        }
        .padding(.vertical, 3)
        .help("选择后立即生效并自动保存；跟随系统会随 macOS 外观自动切换。")
    }
}
