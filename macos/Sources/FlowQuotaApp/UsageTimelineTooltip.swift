import SwiftUI

/// All displayed sources in the hovered interval/direction, without changing layout.
struct UsageTimelineTooltip: View {
    let selection: UsageStackSelection
    let sourceIDs: [String]
    var processSelection: UsageStackSelection?
    var isInterface = false

    private var evidence: [UsageApplicationSource] {
        isInterface ? processSelection?.applications ?? [] : selection.applications
    }
    private var shownEvidence: [UsageApplicationSource] { Array(evidence.prefix(8)) }

    static let width: CGFloat = 272
    var height: CGFloat {
        selection.totalBytes == nil ? 72 : 92 + CGFloat(shownEvidence.count) * 18
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(time(selection.slot.start))–\(time(selection.slot.end))")
                Spacer()
                Text(selection.direction.rawValue)
            }
            .font(.caption.weight(.semibold))
            if let total = selection.totalBytes {
                HStack {
                    Text(isInterface ? "Mac 接口总量" : "来源用量合计").foregroundStyle(.secondary)
                    Spacer()
                    Text(UsageFormatter.bytes(total)).fontWeight(.semibold).monospacedDigit()
                }
                .font(.caption)
                Divider()
                VStack(spacing: 0) {
                    ForEach(shownEvidence) { app in
                        row(app)
                    }
                }
            } else {
                Text("未观测，用量未知").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func row(_ app: UsageApplicationSource) -> some View {
        let selected = selection.source?.id == app.id
        return HStack(spacing: 6) {
            Circle().fill(UsageChartPalette.color(app.id, sources: sourceIDs)).frame(width: 7, height: 7)
            Text(app.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(UsageFormatter.bytes(selection.direction.bytes(upload: app.uploadedBytes, download: app.downloadedBytes)))
                .monospacedDigit().fixedSize()
        }
        .font(.caption)
        .fontWeight(selected ? .semibold : .regular)
        .padding(.horizontal, 3)
        .frame(height: 18)
        .background(selected ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
