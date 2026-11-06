import Foundation

extension StoreSchema {
    static let versionNine = """
        CREATE TABLE clash_source_usage_minutes (
          day TEXT NOT NULL CHECK(\(StoreDay.sqlCheck)),
          category TEXT NOT NULL CHECK(category IN ('metered', 'ordinary')),
          minute_start_ms INTEGER NOT NULL CHECK(typeof(minute_start_ms) = 'integer' AND minute_start_ms >= 0 AND minute_start_ms % 60000 = 0),
          source_id TEXT NOT NULL CHECK(typeof(source_id) = 'text' AND length(CAST(source_id AS BLOB)) BETWEEN 1 AND 8192),
          name TEXT NOT NULL CHECK(typeof(name) = 'text' AND length(CAST(name AS BLOB)) BETWEEN 1 AND 512),
          identified INTEGER NOT NULL CHECK(typeof(identified) = 'integer' AND identified IN (0, 1)),
          uploaded_bytes INTEGER NOT NULL CHECK(typeof(uploaded_bytes) = 'integer' AND uploaded_bytes >= 0),
          downloaded_bytes INTEGER NOT NULL CHECK(typeof(downloaded_bytes) = 'integer' AND downloaded_bytes >= 0),
          sample_count INTEGER NOT NULL CHECK(typeof(sample_count) = 'integer' AND sample_count > 0),
          PRIMARY KEY(day, category, minute_start_ms, source_id),
          CHECK(downloaded_bytes <= 9223372036854775807 - uploaded_bytes)
        )
        """
}
