import SwiftUI

/// Always leads with the meter; losing app identities must never shrink this number.
struct DailyTrafficOverview: View {
    let state: AppState

    private func processBytes(_ direction: UsageDirection) -> Int64? {
        guard state.usageAvailable,
              state.applications.allSatisfy({ state.knownUsage($0) != nil }) else { return nil }
        return UsageFormatter.total(state.applications.map {
            direction.bytes(upload: $0.usage.uploadedBytes, download: $0.usage.downloadedBytes)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日 Mac 总流量").font(.subheadline)
                Spacer()
                Text(UsageFormatter.bytes(state.totalUsage)).font(.title2.bold()).monospacedDigit()
            }
            ForEach(UsageDirection.allCases) { direction in
                let bytes = state.totalUsage.flatMap { _ in state.categoryInterfaceUsage }.map {
                    direction.bytes(upload: $0.uploadedBytes, download: $0.downloadedBytes)
                }
                HStack {
                    Text(direction.rawValue + "核对").font(.caption.weight(.semibold))
                    Spacer()
                    Text(UsageFormatter.bytes(bytes)).font(.caption).monospacedDigit()
                }
                TrafficMeasurementStatus(total: bytes, processes: processBytes(direction))
            }
        }
        .padding(.vertical, 8)
    }
}
