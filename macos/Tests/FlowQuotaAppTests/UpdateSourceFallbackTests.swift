import Foundation
import Sparkle
import Testing
@testable import FlowQuotaApp

@MainActor @Test func fallbackKeepsManualIntentAndResetsToGitHubNextTime() {
    let route = UpdateSourceFallback()
    #expect(route.begin(manual: true) == .probe)
    #expect(route.feedURL == nil)
    #expect(route.probeFinished(failure: "timeout") == .resolveGitee)
    let url = URL(string: "https://gitee.com/feed.xml")!
    #expect(route.resolvedGitee(url) == .probe)
    #expect(route.feedURL == url)
    #expect(route.probeFinished(failure: nil) == .interactive)
    #expect(!route.probing)
    #expect(route.begin(manual: false) == .probe)
    #expect(route.source == "GitHub" && route.feedURL == nil)
    #expect(route.probeFinished(failure: nil) == .done)
}

@MainActor @Test func successfulNoUpdateNeverFallsBackAndQuietCheckNeverOpensUI() {
    for manual in [true, false] {
        let route = UpdateSourceFallback()
        _ = route.begin(manual: manual)
        #expect(route.probeFinished(failure: nil) == (manual ? .interactive : .done))
        #expect(route.source == "GitHub")
    }
}

@MainActor @Test func doubleFailureRetainsBothReasonsAndDoesNotLoop() {
    let route = UpdateSourceFallback()
    _ = route.begin(manual: false)
    #expect(route.probeFinished(failure: "network") == .resolveGitee)
    _ = route.resolvedGitee(URL(string: "https://gitee.com/feed.xml")!)
    #expect(route.probeFinished(failure: "signature") == .failed("GitHub：network\nGitee：signature"))
    #expect(!route.probing)
}

private func release(_ id: Int, _ build: Int, prerelease: Bool = false) -> [String: Any] {
    ["id": id, "tag_name": "v0.1.\(id)", "prerelease": prerelease,
     "body": "notes\n<!-- flow-quota-ready:\(build) -->"]
}

@Test func giteeSelectsHighestReadyBuildRatherThanMostRecentlyModifiedRelease() async throws {
    let releases = try JSONSerialization.data(withJSONObject: [release(1, 31), release(3, 33), release(4, 34, prerelease: true)])
    let assets = Data(#"[{"name":"appcast-arm64.xml","browser_download_url":"https://gitee.com/Leon-wh/flow-quota/releases/download/v0.1.3/appcast-arm64.xml"}]"#.utf8)
    let url = try await GiteeUpdateFeed.resolve(architecture: "arm64") { url in
        if url.path.hasSuffix("/releases") { return releases }
        #expect(url.path.hasSuffix("/releases/3/attach_files"))
        return assets
    }
    #expect(url.host == "gitee.com")
}

@Test func giteeRejectsUnactivatedMissingDuplicateAndForeignFeeds() async throws {
    for assets in ["[]", #"[{"name":"appcast-arm64.xml","browser_download_url":"https://github.com/feed"}]"#,
                   #"[{"name":"appcast-arm64.xml","browser_download_url":"https://gitee.com/feed?access_token=secret"}]"#,
                   #"[{"name":"appcast-arm64.xml","browser_download_url":"http://gitee.com/feed"}]"#] {
        let releases = try JSONSerialization.data(withJSONObject: [release(2, 32)])
        await #expect(throws: (any Error).self) {
            _ = try await GiteeUpdateFeed.resolve(architecture: "arm64") { url in
                url.path.hasSuffix("/releases") ? releases : Data(assets.utf8)
            }
        }
    }
    await #expect(throws: (any Error).self) {
        _ = try await GiteeUpdateFeed.resolve { _ in Data("[]".utf8) }
    }
}

@MainActor @Test func disablingAutomaticChecksStopsSubsequentFallbackButManualStillWorks() {
    let route = UpdateSourceFallback()
    _ = route.begin(manual: false)
    #expect(route.probeFinished(failure: "offline", fallbackAllowed: false) == .failed("GitHub：offline"))
    #expect(!route.probing)
    _ = route.begin(manual: true)
    #expect(route.probeFinished(failure: "offline") == .resolveGitee)
}

@MainActor @Test func updaterQuietFallbackSelectsFeedAndLeavesServiceHandoffUntouched() async throws {
    let suite = "flowquota-fallback-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let url = URL(string: "https://gitee.com/Leon-wh/flow-quota/feed.xml")!
    let app = AppUpdater(defaults: defaults, giteeFeed: { url })
    let sparkle = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
    _ = app.sources.begin(manual: false)
    try app.updater(sparkle, mayPerform: .updateInformation)
    app.updater(sparkle, didFinishUpdateCycleFor: .updateInformation,
                error: URLError(.cannotConnectToHost))
    await app.sourceTask?.value
    #expect(app.feedURLString(for: sparkle) == url.absoluteString)
    #expect(app.pendingSourceCheck == false)
    #expect(app.checking)
    let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
    app.updater(sparkle, didFinishUpdateCycleFor: .updateInformation, error: noUpdate)
    #expect(!app.checking && app.automaticChecks.lastSuccess != nil)
    #expect(!app.installing && !app.recovering && !app.hasPendingInstall && !app.needsRecovery)
}

@Test func giteeRejectsDuplicateAndOversizedMetadata() async throws {
    let releases = try JSONSerialization.data(withJSONObject: [release(2, 32)])
    let duplicate = Data(#"[{"name":"appcast-arm64.xml","browser_download_url":"https://gitee.com/feed"},{"name":"appcast-arm64.xml","browser_download_url":"https://gitee.com/feed"}]"#.utf8)
    await #expect(throws: (any Error).self) {
        _ = try await GiteeUpdateFeed.resolve(architecture: "arm64") { url in
            url.path.hasSuffix("/releases") ? releases : duplicate
        }
    }
    await #expect(throws: (any Error).self) {
        _ = try await GiteeUpdateFeed.resolve { _ in Data(repeating: 32, count: GiteeUpdateFeed.limit + 1) }
    }
}
