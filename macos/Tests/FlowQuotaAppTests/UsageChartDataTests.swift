import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

struct UsageChartDataTests {
    @Test func separatesInterfaceDirectionsAndSortsApplications() throws {
        let day = try LocalDay.key(for: Date(), in: .current)
        let apps = [
            ApplicationSnapshot(identity: AppIdentity(key: "small", name: "小应用"), rule: nil,
                                usage: DailyUsage(appKey: "small", day: day, uploadedBytes: 2, downloadedBytes: 3)),
            ApplicationSnapshot(identity: AppIdentity(key: "large", name: "大应用"), rule: nil,
                                usage: DailyUsage(appKey: "large", day: day, uploadedBytes: 9, downloadedBytes: 11)),
            ApplicationSnapshot(identity: AppIdentity(key: "old", name: "旧数据"), rule: nil,
                                usage: DailyUsage(appKey: "old", day: "2000-01-01", uploadedBytes: 100, downloadedBytes: 100))
        ]
        let data = UsageChartData.make(
            interfaceUsage: InterfaceUsage(day: day, uploadedBytes: 120, downloadedBytes: 80),
            applications: apps, today: day, dailyInterfaceThreshold: 1_000, limit: 8
        )

        #expect(data.interfaceValues.map { $0.bytes } == [120, 80])
        #expect(data.applicationValues.map { $0.id } == ["large", "small"])
        #expect(data.dailyInterfaceThreshold == 1_000)
    }

    @Test func rejectsInvalidAndDifferentDayData() throws {
        let day = try LocalDay.key(for: Date(), in: .current)
        let data = UsageChartData.make(
            interfaceUsage: InterfaceUsage(day: "2000-01-01", uploadedBytes: 10, downloadedBytes: 10),
            applications: [ApplicationSnapshot(
                identity: AppIdentity(key: "invalid", name: "无效"), rule: nil,
                usage: DailyUsage(appKey: "invalid", day: day, uploadedBytes: -1, downloadedBytes: 10)
            )],
            today: day, dailyInterfaceThreshold: nil
        )

        #expect(data.interfaceValues.isEmpty)
        #expect(data.applicationValues.isEmpty)
    }
}
