import Foundation
import Testing
@testable import FlowQuotaCore
@testable import FlowQuotaPlatform

@Test func ruleIPCRejectsUnvalidatedDecodedData() throws {
    let data = Data(#"{"limitBytes":-1,"warningPercent":80,"version":1}"#.utf8)
    #expect(throws: RuleError.invalidLimit) {
        try JSONDecoder().decode(QuotaRule.self, from: data)
    }
}

@Test func commandRoundTripPreservesRuleVersion() throws {
    let rule = try QuotaRule(limitBytes: 500_000_000, warningPercent: 80, version: 7)
    let encoded = try JSONEncoder().encode(AgentRequest.saveRule(appKey: "verified.identity", rule: rule))
    let decoded = try JSONDecoder().decode(AgentRequest.self, from: encoded)
    guard case .saveRule(let key, let decodedRule) = decoded else {
        Issue.record("Expected rule operation")
        return
    }
    #expect(key == "verified.identity")
    #expect(decodedRule == rule)
}

@Test func malformedReplyCannotBecomeProtectionReady() {
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(AgentReply.self, from: Data(#"{"acknowledged":{"ready":true}}"#.utf8))
            .requireSnapshotForTest()
    }
}

private extension AgentReply {
    func requireSnapshotForTest() throws -> AgentSnapshot {
        guard case .snapshot(let snapshot) = self else { throw PlatformError.malformedReply }
        return snapshot
    }
}

@Test func peerIdentityRequiresActualCode() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("not executable code".utf8).write(to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) {
        try PeerRequirement.string(forExecutable: root)
    }
}

@Test func unbundledHelperIsRejected() {
    #expect(throws: (any Error).self) {
        try PeerRequirement.containingApp(executable: URL(fileURLWithPath: "/tmp/FlowQuotaAgent"))
    }
}
