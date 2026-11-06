import FlowQuotaCore
import Observation

/// Window navigation belongs to the UI; both surfaces share the existing AppState.
@MainActor @Observable
final class PreferencesNavigation {
    enum Page: String, CaseIterable, Identifiable {
        case applications, charts, details, reminders, history, general, help
        var id: Self { self }
        var title: String {
            switch self {
            case .applications: "应用用量"
            case .charts: "用量图表"
            case .details: "计量详情"
            case .reminders: "预警设置"
            case .history: "预警记录"
            case .general: "通用设置"
            case .help: "使用说明"
            }
        }
        var symbol: String {
            switch self {
            case .applications: "square.grid.2x2"
            case .charts: "chart.pie"
            case .details: "network"
            case .reminders: "bell"
            case .history: "clock.arrow.circlepath"
            case .general: "gearshape"
            case .help: "questionmark.circle"
            }
        }
    }

    var page: Page = .applications
    var application: ApplicationSnapshot?

    func select(_ page: Page) {
        self.page = page
        application = nil
    }
}
