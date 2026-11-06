import Testing
@testable import FlowQuotaApp

struct UsagePieDataTests {
    @Test func keepsEveryNamedApplicationWithoutMergingTail() throws {
        let values = (1...8).map { UsageChartValue(id: "\($0)", label: "同名应用", bytes: Int64($0)) }
        let data = try #require(UsagePieData.make(values))
        #expect(data.totalBytes == 36)
        #expect(data.slices.map(\.bytes) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(data.slices.allSatisfy { $0.label == "同名应用" })
        #expect(Set(data.slices.map(\.id)).count == 8) // duplicate names are still separate slices
    }

    @Test func onlyPlotsPositiveValuesAndRefusesOverflow() throws {
        let data = try #require(UsagePieData.make([
            UsageChartValue(id: "zero", label: "零用量", bytes: 0),
            UsageChartValue(id: "download", label: "下载", bytes: 100)
        ]))
        #expect(data.slices.count == 1)
        #expect(data.totalBytes == 100)
        #expect(UsagePieData.make([])?.totalBytes == 0)
        #expect(UsagePieData.make([UsageChartValue(id: "bad", label: "bad", bytes: -1)]) == nil)
        #expect(UsagePieData.make([
            UsageChartValue(id: "a", label: "a", bytes: .max),
            UsageChartValue(id: "b", label: "b", bytes: 1)
        ]) == nil)
    }
}
