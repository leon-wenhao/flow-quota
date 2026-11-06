import Foundation

extension StoreSchema {
    static let categoryColumn = "category TEXT NOT NULL DEFAULT 'metered' CHECK(category IN ('metered', 'ordinary'))"

    /// Deliberate v4 -> v5 primary-key migration. Only child tables without inbound
    /// FKs are replaced; every row is copied atomically with its original values.
    /// Reuse the original definitions so byte/type/day constraints stay identical.
    static let versionFive: [String] = {
        var statements: [String] = []
        let tables: [(String, String, String, String)] = [
            ("quota_rules", versionOne[1], "app_key, limit_bytes, warning_percent, version", "app_key, category"),
            ("daily_usage", versionOne[2], "app_key, day, uploaded_bytes, downloaded_bytes", "app_key, day, category"),
            ("notification_receipts", versionOne[3], "app_key, day, kind, rule_version", "app_key, day, kind, rule_version, category"),
            ("daily_interface_usage", versionThree[0], "day, uploaded_bytes, downloaded_bytes", "day, category")
        ]
        for (name, original, columns, key) in tables {
            var definition = original.replacingOccurrences(of: "CREATE TABLE \(name)", with: "CREATE TABLE \(name)_v5")
            if name == "quota_rules" || name == "daily_interface_usage" {
                definition = definition.replacingOccurrences(of: " PRIMARY KEY", with: "")
            } else {
                let oldKey = name == "daily_usage" ? "app_key, day" : "app_key, day, kind, rule_version"
                definition = definition.replacingOccurrences(of: "PRIMARY KEY(\(oldKey))", with: "PRIMARY KEY(\(key))")
            }
            definition = definition.replacingOccurrences(of: "CREATE TABLE \(name)_v5 (",
                with: "CREATE TABLE \(name)_v5 (\(categoryColumn), ")
            let end = definition.lastIndex(of: ")")!
            let extraKey = name == "quota_rules" || name == "daily_interface_usage" ? ", PRIMARY KEY(\(key))" : ""
            definition.insert(contentsOf: extraKey, at: end)
            statements += [definition,
                "INSERT INTO \(name)_v5 (\(columns), category) SELECT \(columns), 'metered' FROM \(name)",
                "DROP TABLE \(name)", "ALTER TABLE \(name)_v5 RENAME TO \(name)"]
        }
        let settings = versionFour[0].replacingOccurrences(of: "CREATE TABLE traffic_alert_settings", with: "CREATE TABLE traffic_alert_settings_v5")
            .replacingOccurrences(of: "id INTEGER NOT NULL PRIMARY KEY CHECK(typeof(id) = 'integer' AND id = 1)",
                with: "category TEXT NOT NULL PRIMARY KEY CHECK(category IN ('metered', 'ordinary'))")
        statements += [settings,
            """
            INSERT INTO traffic_alert_settings_v5
            SELECT 'metered', daily_interface_bytes, interface_burst_bytes, application_burst_bytes,
                window_seconds, cooldown_seconds, version FROM traffic_alert_settings WHERE id = 1
            """,
            "INSERT INTO traffic_alert_settings_v5 VALUES ('ordinary', NULL, NULL, NULL, 180, 600, 1)",
            "DROP TABLE traffic_alert_settings",
            "ALTER TABLE traffic_alert_settings_v5 RENAME TO traffic_alert_settings",
            "ALTER TABLE traffic_alert_events ADD COLUMN \(categoryColumn)",
            "DROP INDEX traffic_alert_lookup",
            "CREATE INDEX traffic_alert_lookup ON traffic_alert_events(day, category, kind, source_key, policy_version, occurred_at_ms)"]
        return statements
    }()
}
