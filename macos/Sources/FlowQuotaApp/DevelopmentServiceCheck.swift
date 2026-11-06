import Darwin
import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import ServiceManagement

/// Repeatable integration check executed by the real signed application, so
/// SMAppService registration and both XPC peer requirements use its identity.
@MainActor enum DevelopmentServiceCheck {
    static func startIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let paused = arguments.contains("--verify-agent-paused") || arguments.contains("--repair-agent-paused")
        let repair = arguments.contains("--repair-agent-service") || arguments.contains("--repair-agent-paused")
        guard paused || repair || arguments.contains("--verify-agent-service") else { return false }
        Task { @MainActor in
            do {
                guard Bundle.main.object(forInfoDictionaryKey: "FlowQuotaDevelopmentBuild") as? Bool == true else {
                    throw PlatformError.unavailable("服务自检只适用于开发构建。")
                }
                let client = AgentClient()
                if repair { try await client.repairDevelopmentAgent(startMonitoring: !paused) }
                if paused { try await client.stopProtection() }
                let first = try await client.fetchSnapshot()
                try await Task.sleep(for: .seconds(4))
                let second = try await client.fetchSnapshot()
                let collectionValid = second.monitoring == .collecting
                    && second.sampledAt.map {
                        $0 > (first.sampledAt ?? .distantPast) && abs(Date().timeIntervalSince($0)) < 10
                    } == true
                let pauseValid = second.monitoring == .paused
                    && second.sampledAt == first.sampledAt
                    && second.interfaceSampledAt == first.interfaceSampledAt
                    && second.notifications.isEmpty && second.pendingTrafficAlerts.isEmpty
                    && (!repair || (first.sampledAt == nil && first.interfaceSampledAt == nil))
                guard second.generatedAt > first.generatedAt, paused ? pauseValid : collectionValid else {
                    throw PlatformError.unavailable("XPC 已连接，但服务状态尚未通过自检：\(second.monitoring.rawValue)。")
                }
                guard let policy = second.trafficAlertPolicy else { throw TrafficAlertError.invalidPolicy }
                try policy.validate()
                let day = try LocalDay.key(for: Date(), in: .current)
                let history = try await client.fetchTrafficAlertHistory(day: day, offset: 0)
                guard history.count <= 32, history.allSatisfy({ $0.day == day }) else {
                    throw TrafficAlertError.invalidEvent
                }
                for event in history { try event.validate() }
                guard let categories = second.trafficCategories,
                      categories.count == TrafficCategory.allCases.count,
                      Set(categories.map(\.category)) == Set(TrafficCategory.allCases) else {
                    throw PlatformError.unavailable("服务尚未提供完整的两类网络账本。")
                }
                for data in categories {
                    try data.trafficAlertPolicy.validate()
                    let page = try await client.fetchTrafficAlertHistory(day: day, offset: 0, category: data.category)
                    guard page.count <= 32, page.allSatisfy({ $0.day == day && $0.category == data.category }) else {
                        throw TrafficAlertError.invalidEvent
                    }
                    for event in page { try event.validate() }
                }
                // Exercise the same bounded query as the chart without starting collection.
                let chartStart = Calendar.current.startOfDay(for: Date())
                let chartEnd = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970 / 60) * 60)
                for category in TrafficCategory.allCases {
                    let query = ApplicationTimelineQuery(day: day, category: category, start: chartStart, end: chartEnd)
                    let timeline = try await client.fetchApplicationTimeline(query)
                    guard timeline.query == query, timeline.buckets.count <= ApplicationUsageTimeline.maximumRows,
                          ApplicationTimelinePresentation.make(timeline) != nil else {
                        throw PlatformError.malformedReply
                    }
                }
                let ordinary = categories.first { $0.category == .ordinary }!.trafficAlertPolicy
                // Only status metadata; never dump application paths, usage or rules.
                let result = Result(bundlePath: Bundle.main.bundlePath,
                    serviceStatus: SMAppService.agent(plistName: AgentEndpoint.launchAgentPlist).status.rawValue,
                    monitoring: second.monitoring.rawValue, network: second.network, applicationCount: second.applications.count,
                    generatedAt: second.generatedAt, sampledAt: second.sampledAt,
                    interfaceSampledAt: second.interfaceSampledAt, pausedCheck: paused,
                    trafficAlertPolicyVersion: policy.version, trafficAlertCount: second.trafficAlertEvents.count,
                    pendingTrafficAlertCount: second.pendingTrafficAlerts.count, historyPageCount: history.count,
                    trafficCategories: categories.map { $0.category.rawValue },
                    ordinaryRemindersEnabled: TrafficAlertKind.allCases.contains { ordinary.threshold(for: $0) != nil })
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                FileHandle.standardOutput.write(try encoder.encode(result))
                FileHandle.standardOutput.write(Data("\n".utf8))
                // Preserve the checked state: paused checks never resume collection.
                // No application termination delegate is involved in this CLI mode.
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Flow Quota 服务自检失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        return true
    }

    private struct Result: Encodable {
        let bundlePath: String
        let serviceStatus: Int
        let monitoring: String
        let network: NetworkState
        let applicationCount: Int
        let generatedAt: Date
        let sampledAt: Date?
        let interfaceSampledAt: Date?
        let pausedCheck: Bool
        let trafficAlertPolicyVersion: Int64
        let trafficAlertCount: Int
        let pendingTrafficAlertCount: Int
        let historyPageCount: Int
        let trafficCategories: [String]
        let ordinaryRemindersEnabled: Bool
    }
}
