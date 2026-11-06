import AppKit
import SwiftUI

/// Local display preference only; no service request or database write is needed.
enum AppAppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appAppearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    static func selection(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }

    /// nil restores native inheritance, so subsequent macOS appearance changes apply.
    @MainActor func apply(to application: NSApplication = .shared) {
        switch self {
        case .system: application.appearance = nil
        case .light: application.appearance = NSAppearance(named: .aqua)
        case .dark: application.appearance = NSAppearance(named: .darkAqua)
        }
        // A previously hosted window can retain a local appearance override.
        // Clear it so every window inherits the newly selected application style.
        for window in application.windows { window.appearance = nil }
    }
}

/// Each independently hosted surface observes the same saved choice. AppKit owns
/// the window and menu-bar surface appearance so returning to system mode clears
/// both the title-bar and the hosted SwiftUI content style.
private struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearancePreference.key) private var storedAppearance = AppAppearancePreference.system.rawValue
    func body(content: Content) -> some View {
        content
            .onChange(of: storedAppearance, initial: true) { _, rawValue in
                (AppAppearancePreference(rawValue: rawValue) ?? .system).apply()
            }
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
}
