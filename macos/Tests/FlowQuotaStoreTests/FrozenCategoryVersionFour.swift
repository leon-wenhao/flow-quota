import Foundation

// Frozen v4 alert DDL; deliberately independent from the v5 production migration.
enum FrozenCategoryVersionFour {
    // Exactly two entities and one explicit index. No mutable-policy/application FK:
    // evidence survives policy changes and process disappearance until day pruning.
    static let schema = [
        """
        CREATE TABLE traffic_alert_settings (
          id INTEGER NOT NULL PRIMARY KEY CHECK(typeof(id) = 'integer' AND id = 1),
          daily_interface_bytes INTEGER CHECK(daily_interface_bytes IS NULL OR
            (typeof(daily_interface_bytes) = 'integer' AND daily_interface_bytes > 0)),
          interface_burst_bytes INTEGER CHECK(interface_burst_bytes IS NULL OR
            (typeof(interface_burst_bytes) = 'integer' AND interface_burst_bytes > 0)),
          application_burst_bytes INTEGER CHECK(application_burst_bytes IS NULL OR
            (typeof(application_burst_bytes) = 'integer' AND application_burst_bytes > 0)),
          window_seconds INTEGER NOT NULL CHECK(typeof(window_seconds) = 'integer' AND window_seconds BETWEEN 60 AND 900),
          cooldown_seconds INTEGER NOT NULL CHECK(typeof(cooldown_seconds) = 'integer' AND cooldown_seconds BETWEEN 60 AND 86400),
          version INTEGER NOT NULL CHECK(typeof(version) = 'integer' AND version > 0)
        )
        """,
        """
        CREATE TABLE traffic_alert_events (
          id TEXT NOT NULL PRIMARY KEY CHECK(typeof(id) = 'text' AND length(id) = 36
            AND instr(id, char(0)) = 0 AND substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-'
            AND substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-'
            AND length(replace(id, '-', '')) = 32
            AND id NOT GLOB '*[^0-9A-F-]*'),
          day TEXT NOT NULL CHECK(\(FrozenAlertVersionThree.dayCheck) AND instr(day, char(0)) = 0),
          kind TEXT NOT NULL CHECK(typeof(kind) = 'text'
            AND kind IN ('dailyInterface', 'interfaceBurst', 'applicationBurst')),
          source_key TEXT NOT NULL CHECK(typeof(source_key) = 'text'
            AND length(CAST(source_key AS BLOB)) <= 2048 AND instr(source_key, char(0)) = 0),
          source_name TEXT NOT NULL CHECK(typeof(source_name) = 'text'
            AND length(CAST(source_name AS BLOB)) BETWEEN 1 AND 256
            AND length(trim(source_name, char(9, 10, 11, 12, 13, 32))) > 0 AND instr(source_name, char(0)) = 0),
          observed_bytes INTEGER NOT NULL CHECK(typeof(observed_bytes) = 'integer' AND observed_bytes >= threshold_bytes),
          threshold_bytes INTEGER NOT NULL CHECK(typeof(threshold_bytes) = 'integer' AND threshold_bytes > 0),
          window_seconds INTEGER NOT NULL CHECK(typeof(window_seconds) = 'integer'),
          observed_seconds INTEGER NOT NULL CHECK(typeof(observed_seconds) = 'integer'),
          policy_version INTEGER NOT NULL CHECK(typeof(policy_version) = 'integer' AND policy_version > 0),
          occurred_at_ms INTEGER NOT NULL CHECK(typeof(occurred_at_ms) = 'integer'
            AND occurred_at_ms BETWEEN 1 AND 253402300799999),
          scheduled_at_ms INTEGER CHECK(scheduled_at_ms IS NULL OR
            (typeof(scheduled_at_ms) = 'integer' AND scheduled_at_ms BETWEEN occurred_at_ms AND 253402300799999)),
          CHECK((kind = 'applicationBurst' AND length(trim(source_key, char(9, 10, 11, 12, 13, 32))) > 0)
            OR (kind IN ('dailyInterface', 'interfaceBurst') AND source_key = '')),
          CHECK((kind = 'dailyInterface' AND window_seconds = 0 AND observed_seconds = 0)
            OR (kind IN ('interfaceBurst', 'applicationBurst') AND window_seconds BETWEEN 60 AND 900
              AND observed_seconds BETWEEN 1 AND window_seconds))
        )
        """,
        """
        CREATE INDEX traffic_alert_lookup ON traffic_alert_events(day, kind, source_key, policy_version, occurred_at_ms)
        """,
        """
        INSERT INTO traffic_alert_settings VALUES (1, 1000000000, 200000000, 200000000, 180, 600, 1)
        """
    ]
}
