import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaStore

@Test func canonicalEquivalentKeysCannotCreateTwoBudgets() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let store = try fixture.open()
    let canonical = "signed:caf\u{00E9}"
    let decomposed = "signed:cafe\u{0301}"
    #expect(canonical == decomposed)
    try await fixture.seed(store, key: canonical)
    await expectStoreError(.invalidIdentifier) {
        try await store.registerApplication(AppIdentity(key: decomposed, name: "Other"))
    }
    await expectStoreError(.invalidIdentifier) {
        try await store.recordUsage(appKey: decomposed, day: fixture.day, uploadedBytes: 1, downloadedBytes: 0)
    }
    #expect(throws: QuotaIdentityError.invalidAppKey) {
        try QuotaIdentity(appKey: decomposed, day: fixture.day, ruleVersion: 1)
    }
    #expect(try await store.loadRules().count == 1)
    try await store.close()
}

@Test func legacyNoncanonicalKeysFailOpenWithoutMergingUsage() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let store = try fixture.open()
    try await fixture.seed(store, key: "signed:caf\u{00E9}")
    try await store.close()
    let database = try SQLiteConnection(path: fixture.path)
    try database.execute("INSERT INTO applications VALUES (?, 'Legacy')", [.text("signed:cafe\u{0301}")])
    #expect(throws: StoreError.invalidIdentifier) { try fixture.open() }
    #expect(try database.scalar("SELECT COUNT(*) FROM applications") == 2)
    #expect(try database.scalar("SELECT COUNT(*) FROM quota_rules") == 1)
    try database.close()
}
