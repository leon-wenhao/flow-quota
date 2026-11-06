import SwiftUI

/// Shared row geometry keeps ordinary apps and attributed Clash sources aligned.
struct TrafficSourceRowContent: View {
    let name: String
    let symbol: String
    let status: String
    let usage: String
    let scope: String
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            ApplicationSourceMark(name: name, symbol: symbol, size: compact ? 24 : 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !compact { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(usage).font(.subheadline.weight(.medium)).monospacedDigit()
                if !compact { Text(scope).font(.caption2).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(height: compact ? 32 : 58)
        .contentShape(Rectangle())
    }
}
