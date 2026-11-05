import Foundation

/// Daily observed link counters, independent of application attribution. A missing
/// value means no valid interface baseline, never a reconstructed app sum.
public struct InterfaceUsage: Codable, Sendable, Equatable {
    public let day: String
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64

    public init(day: String, uploadedBytes: Int64, downloadedBytes: Int64) {
        self.day = day
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
    }

    public var totalBytes: Int64? {
        guard uploadedBytes >= 0, downloadedBytes >= 0 else { return nil }
        let (total, overflow) = uploadedBytes.addingReportingOverflow(downloadedBytes)
        return overflow ? nil : total
    }
}
