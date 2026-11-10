import FlowQuotaCore
import Observation

/// Window navigation belongs to the UI; both surfaces share the existing AppState.
@MainActor @Observable
final class PreferencesNavigation {
    enum Page: String, CaseIterable, Identifiable {
        case applications, charts, details, reminders, history, general, help, about
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
            case .about: "关于"
            }
        }
        var symbol: String {
            switch self {
            case .applications: "square.grid.2x2.fill"
            case .charts: "chart.pie.fill"
            case .details: "network"
            case .reminders: "bell.badge.fill"
            case .history: "clock.arrow.circlepath"
            case .general: "gearshape.fill"
            case .help: "questionmark.circle.fill"
            case .about: "info.circle.fill"
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
