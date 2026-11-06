import Foundation
import Testing
@testable import FlowQuotaApp

private struct StubUpdateLoader: UpdateDataLoading {
    let data: Data
    let response: URLResponse

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (data, response)
    }
}

struct UpdateCheckerTests {
    @Test func defaultUpdateEndpointUsesPublicDistributionRepository() {
        #expect(UpdateChecker.defaultManifestURL.absoluteString ==
            "https://raw.githubusercontent.com/leon-wenhao/flow-quota-releases/main/update-manifest.json")
    }

    @Test func comparesMarketingVersionThenBuild() throws {
        let current = try AppVersion(version: "1.2.0", build: 4)
        let sameMarketingNewBuild = try AppVersion(version: "1.2.0", build: 5)
        let newMarketing = try AppVersion(version: "1.3.0", build: 1)
        let oldMarketing = try AppVersion(version: "1.1.9", build: 99)

        #expect(sameMarketingNewBuild > current)
        #expect(newMarketing > sameMarketingNewBuild)
        #expect(oldMarketing < current)
        #expect((try AppVersion(version: "v1.2")) == (try AppVersion(version: "1.2.0")))
    }

    @Test func decodesAndValidatesManifest() throws {
        let data = Data("{\"version\":\"0.2.0\",\"build\":2,\"minimumSystemVersion\":\"14.0\",\"releaseNotesURL\":\"https://example.com/release-notes\",\"downloadURL\":\"https://example.com/FlowQuota.dmg\",\"publishedAt\":\"2026-11-05T00:00:00Z\"}".utf8)
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        let release = try manifest.release()

        #expect(release.version == (try AppVersion(version: "0.2.0", build: 2)))
        #expect(release.downloadURL.absoluteString == "https://example.com/FlowQuota.dmg")
        #expect(release.minimumSystemVersion == "14.0")
    }

    @Test func rejectsInsecureDownloadURL() throws {
        let data = Data("{\"version\":\"0.2.0\",\"build\":2,\"releaseNotesURL\":\"https://example.com/release-notes\",\"downloadURL\":\"http://example.com/FlowQuota.dmg\"}".utf8)
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)

        #expect(throws: UpdateCheckError.invalidManifest) {
            try manifest.release()
        }
    }

    @Test func checksLatestManifestAndHandlesHTTPFailure() async throws {
        let manifestData = Data("{\"version\":\"0.2.0\",\"build\":2,\"downloadURL\":\"https://example.com/FlowQuota.dmg\"}".utf8)
        let url = URL(string: "https://example.com/update-manifest.json")!
        let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let checker = UpdateChecker(endpoint: url, loader: StubUpdateLoader(data: manifestData, response: success))
        let result = try await checker.check(current: try AppVersion(version: "0.1.0", build: 1))
        guard case .available(let release) = result else {
            Issue.record("Expected an available update")
            return
        }
        #expect(release.version == (try AppVersion(version: "0.2.0", build: 2)))

        let failure = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
        let failedChecker = UpdateChecker(endpoint: url, loader: StubUpdateLoader(data: Data(), response: failure))
        await #expect(throws: UpdateCheckError.httpStatus(503)) {
            try await failedChecker.check(current: try AppVersion(version: "0.1.0", build: 1))
        }
    }

    @Test func selectsCurrentArchitecturePackageAndValidatesMetadata() throws {
        let package = """
        {"format":"dmg","fileName":"FlowQuota-0.2.0-ARCH.dmg","url":"https://github.com/example/flow-quota/releases/download/v0.2.0/FlowQuota-0.2.0-ARCH.dmg","size":4,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
        """.replacingOccurrences(of: "ARCH", with: UpdateArchitecture.current)
        let data = Data("""
        {"schemaVersion":2,"product":"flow-quota","channel":"stable","version":"0.2.0","build":2,"minimumSystemVersion":"14.0","releaseNotesURL":"https://github.com/example/flow-quota/releases/tag/v0.2.0","downloadURL":"https://github.com/example/flow-quota/releases/tag/v0.2.0","packages":{"macos/\(UpdateArchitecture.current)":\(package)}}
        """.utf8)

        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        let release = try manifest.release()

        #expect(release.package?.fileName.contains(UpdateArchitecture.current) == true)
        #expect(release.package?.size == 4)
        #expect(release.downloadURL.absoluteString.contains("releases/download/v0.2.0"))
    }

    @Test func rejectsPackageWithoutCurrentArchitecture() throws {
        let data = Data("""
        {"schemaVersion":2,"product":"flow-quota","channel":"stable","version":"0.2.0","build":2,"downloadURL":"https://github.com/example/flow-quota/releases/tag/v0.2.0","packages":{"macos/other":{"format":"dmg","fileName":"FlowQuota-0.2.0-other.dmg","url":"https://github.com/example/flow-quota/releases/download/v0.2.0/FlowQuota-0.2.0-other.dmg","size":4,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}}}
        """.utf8)
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)

        #expect(throws: UpdateCheckError.packageUnavailable(UpdateArchitecture.current)) {
            try manifest.release()
        }
    }
}
