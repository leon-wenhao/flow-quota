import SwiftUI

/// Native button roles and keyboard behavior, with consistent settings-page sizing.
private struct SettingsActionStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        Group {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
        .controlSize(.regular)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .font(.subheadline.weight(.medium))
    }
}

extension View {
    func settingsAction(prominent: Bool = false) -> some View {
        modifier(SettingsActionStyle(prominent: prominent))
    }
}
