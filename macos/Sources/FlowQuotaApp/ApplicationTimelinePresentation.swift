import Foundation
import FlowQuotaCore

enum UsageDirection: String, CaseIterable, Identifiable {
    case upload = "上传", download = "下载"
    var id: String { rawValue }
    func bytes(upload: Int64, download: Int64) -> Int64 { self == .upload ? upload : download }
}

struct UsageApplicationSource: Identifiable, Equatable {
    let id: String
    let name: String
    let uploadedBytes: Int64
    let downloadedBytes: Int64
}

struct UsageStackSegment: Identifiable {
    var id: String { "\(slotIndex):\(direction.id):\(source.id)" }
    let slotIndex: Int
    let direction: UsageDirection
    let source: UsageApplicationSource
    let lower: Int64
    let upper: Int64
    var bytes: Int64 { upper - lower }
}

struct UsageStackSelection {
    let slot: UsageTimeSlot
    let direction: UsageDirection
    let source: UsageApplicationSource?
    let bytes: Int64?
    /// Observed sources for this interval only, retaining measured zeros.
    let applications: [UsageApplicationSource]
    var totalBytes: Int64? {
        slot.sampleCount > 0 ? direction.bytes(upload: slot.uploadedBytes, download: slot.downloadedBytes) : nil
    }
}

/// Pure, checked presentation of the service's bounded interval result. Source
/// identities, not display names, determine colors and stack/sector membership.
struct ApplicationTimelinePresentation {
    let summary: UsageTimelineData
    let sources: [UsageApplicationSource]
    let segments: [UsageStackSegment]
    let slotSources: [[UsageApplicationSource]]
    let clashNotice: String?

    static func make(_ result: ApplicationUsageTimeline) -> ApplicationTimelinePresentation? {
        let scopedRows = result.buckets.filter { result.sourcesResolved == true || $0.clashSourceID == nil }
        let query = result.query
        let duration = query.end.timeIntervalSince(query.start)
        guard query.start.timeIntervalSince1970.isFinite, duration.isFinite,
              [5, 30].contains(result.bucketMinutes), duration > 0, duration <= 90_000,
              result.buckets.count <= ApplicationUsageTimeline.maximumRows else { return nil }
        let step = Double(result.bucketMinutes * 60)
        let count = Int(ceil(duration / step))
        guard count <= ApplicationUsageTimeline.maximumTimeBuckets else { return nil }
        var slots = (0..<count).map { index in
            UsageTimeSlot(start: query.start.addingTimeInterval(Double(index) * step),
                end: min(query.end, query.start.addingTimeInterval(Double(index + 1) * step)))
        }
        var totals: [String: UsageApplicationSource] = [:]
        var seen = Set<String>()
        for row in scopedRows {
            let date = Date(timeIntervalSince1970: Double(row.startMilliseconds) / 1_000)
            let offset = date.timeIntervalSince(query.start)
            guard offset >= 0, offset < duration, offset.truncatingRemainder(dividingBy: step) == 0,
                  row.uploadedBytes >= 0, row.downloadedBytes >= 0, row.sampleCount > 0,
                  seen.insert(row.id).inserted else { return nil }
            let index = Int(offset / step)
            let old = totals[row.sourceID]
            guard old == nil || old?.name == row.name,
                  let upload = UsageFormatter.total([old?.uploadedBytes ?? 0, row.uploadedBytes]),
                  let download = UsageFormatter.total([old?.downloadedBytes ?? 0, row.downloadedBytes]),
                  UsageFormatter.total([upload, download]) != nil,
                  let slotUpload = UsageFormatter.total([slots[index].uploadedBytes, row.uploadedBytes]),
                  let slotDownload = UsageFormatter.total([slots[index].downloadedBytes, row.downloadedBytes]),
                  let samples = UsageFormatter.total([slots[index].sampleCount, row.sampleCount]),
                  UsageFormatter.total([slotUpload, slotDownload]) != nil else { return nil }
            totals[row.sourceID] = UsageApplicationSource(id: row.sourceID, name: row.name,
                uploadedBytes: upload, downloadedBytes: download)
            slots[index].uploadedBytes = slotUpload
            slots[index].downloadedBytes = slotDownload
            slots[index].sampleCount = samples
        }
        let sources = totals.values.sorted {
            if $0.id == "remaining" { return false }
            if $1.id == "remaining" { return true }
            let lhs = $0.uploadedBytes + $0.downloadedBytes
            let rhs = $1.uploadedBytes + $1.downloadedBytes
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        guard sources.count <= ApplicationUsageTimeline.maximumNamedSources + 1 else { return nil }
        let observed = slots.filter { $0.sampleCount > 0 }
        let upload = UsageFormatter.total(observed.map(\.uploadedBytes))
        let download = UsageFormatter.total(observed.map(\.downloadedBytes))
        guard let upload, let download, UsageFormatter.total([upload, download]) != nil else { return nil }
        let rows = Dictionary(uniqueKeysWithValues: scopedRows.map { ($0.id, $0) })
        var segments: [UsageStackSegment] = []
        var slotSources = [[UsageApplicationSource]](repeating: [], count: count)
        for (index, slot) in slots.enumerated() {
            let timestamp = Int64((slot.start.timeIntervalSince1970 * 1_000).rounded())
            slotSources[index] = sources.compactMap { source in
                guard let row = rows["\(source.id):\(timestamp)"] else { return nil }
                return UsageApplicationSource(id: source.id, name: source.name,
                    uploadedBytes: row.uploadedBytes, downloadedBytes: row.downloadedBytes)
            }
            for direction in UsageDirection.allCases {
                var lower: Int64 = 0
                for source in sources {
                    guard let row = rows["\(source.id):\(timestamp)"] else { continue }
                    let bytes = direction.bytes(upload: row.uploadedBytes, download: row.downloadedBytes)
                    if bytes > 0 {
                        segments.append(UsageStackSegment(slotIndex: index, direction: direction,
                            source: source, lower: lower, upper: lower + bytes))
                    }
                    lower += bytes
                }
            }
        }
        return ApplicationTimelinePresentation(summary: UsageTimelineData(slots: slots,
            interval: DateInterval(start: query.start, end: query.end), bucketMinutes: result.bucketMinutes,
            uploadedBytes: observed.isEmpty ? nil : upload, downloadedBytes: observed.isEmpty ? nil : download),
            sources: sources, segments: segments, slotSources: slotSources, clashNotice: result.clashNotice)
    }

    func selection(at date: Date, bytes: Double) -> UsageStackSelection? {
        guard let index = summary.slots.firstIndex(where: { $0.start <= date && date < $0.end }) else { return nil }
        let slot = summary.slots[index]
        let fraction = date.timeIntervalSince(slot.start) / slot.end.timeIntervalSince(slot.start)
        let direction: UsageDirection = fraction < 0.5 ? .upload : .download
        let segment = segments.first {
            $0.slotIndex == index && $0.direction == direction && bytes >= Double($0.lower) && bytes < Double($0.upper)
        }
        let total = slot.sampleCount > 0 ? direction.bytes(upload: slot.uploadedBytes, download: slot.downloadedBytes) : nil
        let applications = slotSources[index].sorted {
            if $0.id == "remaining" { return false }
            if $1.id == "remaining" { return true }
            let lhs = direction.bytes(upload: $0.uploadedBytes, download: $0.downloadedBytes)
            let rhs = direction.bytes(upload: $1.uploadedBytes, download: $1.downloadedBytes)
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        return UsageStackSelection(slot: slot, direction: direction,
            source: segment?.source ?? (sources.count == 1 ? sources.first : nil),
            bytes: segment?.bytes ?? total, applications: applications)
    }

    func pie(_ direction: UsageDirection) -> UsagePieData {
        let slices = sources.compactMap { source -> UsagePieSlice? in
            let bytes = direction.bytes(upload: source.uploadedBytes, download: source.downloadedBytes)
            return bytes > 0 ? UsagePieSlice(id: source.id, label: source.name, bytes: bytes) : nil
        }
        return UsagePieData(slices: slices, totalBytes: UsageFormatter.total(slices.map(\.bytes)) ?? 0)
    }
}
