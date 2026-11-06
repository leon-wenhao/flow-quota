import AppKit
import Foundation
import Testing
@testable import FlowQuotaApp

@Test func appearanceChoiceSurvivesReloadAndInvalidPreferenceRestoresSystem() throws {
    let suite = "FlowQuotaTests.appearance.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(AppAppearancePreference.selection(in: defaults) == .system)
    for choice in AppAppearancePreference.allCases {
        defaults.set(choice.rawValue, forKey: AppAppearancePreference.key)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(AppAppearancePreference.selection(in: reopened) == choice)
    }
    defaults.set("invalid", forKey: AppAppearancePreference.key)
    #expect(AppAppearancePreference.selection(in: defaults) == .system)
}

@MainActor @Test func returningToSystemRemovesTheNativeAppearanceOverride() {
    let application = NSApplication.shared
    let previous = application.appearance
    defer { application.appearance = previous }
    AppAppearancePreference.dark.apply(to: application)
    #expect(application.appearance?.name == .darkAqua)
    AppAppearancePreference.light.apply(to: application)
    #expect(application.appearance?.name == .aqua)
    AppAppearancePreference.system.apply(to: application)
    #expect(application.appearance == nil)
}
