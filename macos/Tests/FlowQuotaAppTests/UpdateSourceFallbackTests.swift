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

@Test(arguments: ["arm64", "x86_64"])
func giteeFeedUsesFixedArchitectureFileWithoutReleaseMetadata(architecture: String) async throws {
    let url = try await GiteeUpdateFeed.resolve(architecture: architecture)
    #expect(url.absoluteString == "https://gitee.com/Leon-wh/flow-quota/raw/codex/update-feeds/updates/appcast-\(architecture).xml")
    #expect(url.scheme == "https" && url.host == "gitee.com")
    #expect(url.query == nil && url.fragment == nil && url.user == nil)
}

@Test(arguments: ["", "amd64", "../arm64", "arm64?access_token=secret"])
func giteeFeedRejectsUnsupportedArchitecture(architecture: String) async {
    await #expect(throws: (any Error).self) {
        _ = try await GiteeUpdateFeed.resolve(architecture: architecture)
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
