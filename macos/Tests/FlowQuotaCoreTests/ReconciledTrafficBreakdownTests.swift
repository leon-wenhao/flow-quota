import Testing
@testable import FlowQuotaCore

struct ReconciledTrafficBreakdownTests {
    let minute: Int64 = 1_794_000_000_000

    func parent(_ up: Int64, _ down: Int64) -> InterfaceUsageMinute {
        InterfaceUsageMinute(minuteStartMilliseconds: minute, uploadedBytes: up,
            downloadedBytes: down, sampleCount: 1)
    }

    func app(_ key: String, _ name: String, _ up: Int64, _ down: Int64) -> ApplicationUsageBucket {
        ApplicationUsageBucket(appKey: key, name: name, startMilliseconds: minute,
            uploadedBytes: up, downloadedBytes: down, sampleCount: 1)
    }

    @Test func completeParentKeepsKnownSourcesAndRemainder() throws {
        let result = try ReconciledTrafficBreakdown.resolve(
            interfaceMinutes: [parent(100, 800)],
            processMinutes: [app("exec:/wechat", "微信", 10, 300), app("exec:/feishu", "飞书", 20, 200)],
            clashMinutes: [])
        #expect(result.sources.reduce(0) { $0 + $1.uploadedBytes } == 100)
        #expect(result.sources.reduce(0) { $0 + $1.downloadedBytes } == 800)
        #expect(result.sources.first { $0.appKey == "exec:/wechat" }?.downloadedBytes == 300)
        #expect(result.sources.first { $0.kind == .unidentified }?.downloadedBytes == 300)
        #expect(result.notice?.contains("余量") == true)
    }

    @Test func overBudgetMinuteBecomesEntirelyUnknownWithoutClipping() throws {
        let result = try ReconciledTrafficBreakdown.resolve(
            interfaceMinutes: [parent(100, 800)],
            processMinutes: [app("exec:/wechat", "微信", 101, 900)],
            clashMinutes: [])
        #expect(result.sources.count == 1)
        #expect(result.sources[0].kind == .unidentified)
        #expect(result.sources[0].uploadedBytes == 100)
        #expect(result.sources[0].downloadedBytes == 800)
        #expect(result.notice?.contains("冲突") == true)
    }


    @Test func clashConflictRemainsUnknownAndVisible() throws {
        let result = try ReconciledTrafficBreakdown.resolve(
            interfaceMinutes: [parent(0, 800)],
            processMinutes: [app("exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo", "Mihomo", 0, 800)],
            clashMinutes: [
                ClashMinuteUsage(minute: minute,
                    source: ClashUsageSource(id: "huya", name: "虎牙直播（Clash）", uploadedBytes: 0, downloadedBytes: 900))
            ])
        #expect(result.sources.count == 1)
        #expect(result.sources[0].kind == .unidentified)
        #expect(result.sources[0].downloadedBytes == 800)
        #expect(result.notice?.contains("Clash") == true)
    }

    @Test func clashChildrenAreCountedOnceAndUnknownRemainderIsKept() throws {
        let result = try ReconciledTrafficBreakdown.resolve(
            interfaceMinutes: [parent(0, 800)],
            processMinutes: [app("exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo", "Mihomo", 0, 800)],
            clashMinutes: [
                ClashMinuteUsage(minute: minute,
                    source: ClashUsageSource(id: "huya", name: "虎牙直播（Clash）", uploadedBytes: 0, downloadedBytes: 300)),
                ClashMinuteUsage(minute: minute,
                    source: ClashUsageSource(id: "youtube", name: "YouTube（Clash）", uploadedBytes: 0, downloadedBytes: 300))
            ])
        #expect(result.sources.first { $0.name == "虎牙直播（Clash）" }?.downloadedBytes == 300)
        #expect(result.sources.first { $0.name == "YouTube（Clash）" }?.downloadedBytes == 300)
        #expect(result.sources.first { $0.kind == .unidentified }?.downloadedBytes == 200)
        #expect(result.sources.reduce(0) { $0 + $1.downloadedBytes } == 800)
    }
}
