import Foundation

/// One category's observed interface deltas ending in this UTC minute. A missing
/// row is unknown; a zero-valued row with samples is measured zero. Counts do not
/// imply continuous/full-minute coverage. Day/category belong to the enclosing snapshot.
public struct InterfaceUsageMinute: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64 { minuteStartMilliseconds }
    public let minuteStartMilliseconds: Int64
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64
    public let sampleCount: Int64

    public var start: Date { Date(timeIntervalSince1970: Double(minuteStartMilliseconds) / 1_000) }

    public init(minuteStartMilliseconds: Int64, uploadedBytes: Int64,
                downloadedBytes: Int64, sampleCount: Int64) {
        self.minuteStartMilliseconds = minuteStartMilliseconds
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
        self.sampleCount = sampleCount
    }
}
