import Foundation

/// A local presentation preference, separate from service-owned metering and rules.
/// Limit polling to the existing five-second maximum so notification checks cannot
/// be slowed down, and keep it well within the snapshot's 15-second freshness limit.
enum UsageRefreshPreference {
    static let key = "usageRefreshSeconds"
    static let defaultSeconds = 5
    static let allowedSeconds = 1...5

    static func seconds(in defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: key) as? Int,
              allowedSeconds.contains(value) else { return defaultSeconds }
        return value
    }
}
