import FlowQuotaCore
import SwiftUI

struct TrafficCategorySelection: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FlowQuotaSegmentedControl(
                options: TrafficCategory.allCases,
                selection: Binding(
                    get: { state.selectedTrafficCategory },
                    set: { state.selectedTrafficCategory = $0 }
                ),
                title: { $0.title },
                accessibilityLabel: "统计与提醒类别"
            )
            .frame(maxWidth: .infinity)
            .disabled(state.busy)
        }
    }
}

extension AppState {
    var categorySnapshot: TrafficCategorySnapshot? { snapshot?.usage(for: selectedTrafficCategory) }
    var categoryApplications: [ApplicationSnapshot] {
        categorySnapshot?.applications ?? (selectedTrafficCategory == .metered ? snapshot?.applications ?? [] : [])
    }
    var categoryInterfaceUsage: InterfaceUsage? {
        categorySnapshot?.interfaceUsage ?? (selectedTrafficCategory == .metered ? snapshot?.interfaceUsage : nil)
    }
    var categoryInterfaceSampledAt: Date? {
        categorySnapshot?.interfaceSampledAt ?? (selectedTrafficCategory == .metered ? snapshot?.interfaceSampledAt : nil)
    }
    var categoryPolicy: TrafficAlertPolicy? {
        categorySnapshot?.trafficAlertPolicy ?? (selectedTrafficCategory == .metered ? snapshot?.trafficAlertPolicy : nil)
    }
    var categoryEvents: [TrafficAlertEvent] {
        categorySnapshot?.trafficAlertEvents ?? (selectedTrafficCategory == .metered ? snapshot?.trafficAlertEvents ?? [] : [])
    }
    var categoryAlertMessage: String {
        guard snapshot?.network.trafficCategory == selectedTrafficCategory else {
            return "当前连接不属于\(selectedTrafficCategory.title)；保留该类设置与今日记录。"
        }
        return snapshot?.trafficAlertMessage ?? "预警状态尚未就绪。"
    }
}
