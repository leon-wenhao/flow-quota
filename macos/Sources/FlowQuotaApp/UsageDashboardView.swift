import SwiftUI

struct UsageDashboardView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("用量图表").flowQuotaPageTitle()
            UsageTimelineView(state: state)
        }
    }
}
