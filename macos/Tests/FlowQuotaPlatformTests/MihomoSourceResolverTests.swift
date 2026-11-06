import Foundation
import Testing
@testable import FlowQuotaPlatform
import FlowQuotaCore

private let resolverChromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
private let resolverProxyPath = "/Library/Application Support/clash-verge-service/cores/verge-mihomo"

/// Exercise the controller's decoding contract, including omitted optional fields.
private func resolvedMihomoSource(metadata: [String: String] = [:], chains: [String] = [],
                                  connectionID: String = "fixture", upload: Int64 = 123,
                                  download: Int64 = 456) throws -> MihomoProxySource {
    let data = try JSONSerialization.data(withJSONObject: [
        "uploadTotal": upload, "downloadTotal": download,
        "connections": [["id": connectionID, "upload": upload, "download": download,
                         "metadata": metadata, "chains": chains]]
    ])
    let connection = try #require(MihomoAPIResponse.decode(data).connections.first)
    return MihomoSourceResolver().source(for: connection)
}

@Test func mihomoResolverClassifiesOnlyAllowlistedSitesAndSubdomains() throws {
    for (host, name) in [
        ("youtube.com", "YouTube"), ("www.youtube.com", "YouTube"),
        ("youtu.be", "YouTube"), ("m.youtu.be", "YouTube"),
        ("googlevideo.com", "YouTube"), ("rr1.sn.example.googlevideo.com", "YouTube"),
        ("ytimg.com", "YouTube"), ("i.ytimg.com", "YouTube"),
        ("huya.com", "虎牙直播"), ("www.huya.com", "虎牙直播"),
        ("huya.tv", "虎牙直播"), ("live.huya.tv", "虎牙直播"),
        ("huyacdn.com", "虎牙直播"), ("pull.huyacdn.com", "虎牙直播")
    ] {
        let source = try resolvedMihomoSource(metadata: ["host": host, "processPath": resolverChromePath])
        #expect(source.siteName == name)
        #expect(source.displayName == name + "（Clash）")
        #expect(source.appIdentity?.key == "app:/Applications/Google Chrome.app")
        #expect(source.viaClash == true)
    }
}

@Test func mihomoResolverNormalizesHostCaseAndOneTerminalDot() throws {
    for host in ["YOUTUBE.COM", "WWW.YouTube.Com.", "RR1.GOOGLEVIDEO.COM."] {
        #expect(try resolvedMihomoSource(metadata: ["sniffHost": host]).siteName == "YouTube")
    }
    #expect(try resolvedMihomoSource(metadata: ["host": "LIVE.HUYA.TV."]).siteName == "虎牙直播")
}

@Test func mihomoResolverRejectsSpoofedAndMalformedHosts() throws {
    for host in [
        "notyoutube.com", "youtube.com.attacker.test", "youtube.com.evil.", "fakeyoutu.be",
        "notgooglevideo.com", "ytimg.com.evil", "nothuya.com", "huya.tv.attacker.test",
        "fakehuyacdn.com", "https://youtube.com", "youtube.com:443", "user@youtube.com",
        "youtube.com/", ".youtube.com", "a..youtube.com", "youtube.com..",
        "-bad.youtube.com", "bad-.youtube.com", " youtube.com", "youtube.com\n",
        "youtube.com\0", "💻.youtube.com", "", "192.0.2.1"
    ] {
        let source = try resolvedMihomoSource(metadata: ["host": host, "processPath": resolverChromePath])
        #expect(source.siteName == nil)
        #expect(source.displayName == "Google Chrome（Clash）")
    }
}

@Test func mihomoResolverUsesNonemptySniffHostAndRejectsRecognizedConflicts() throws {
    for metadata in [
        ["sniffHost": "i.ytimg.com", "host": "example.test"],
        ["sniffHost": "www.youtube.com", "host": "rr1.googlevideo.com"],
        ["sniffHost": "", "host": "youtube.com"],
        ["host": "youtube.com"], ["sniffHost": "youtu.be"]
    ] {
        #expect(try resolvedMihomoSource(metadata: metadata).siteName == "YouTube")
    }
    for (sniffHost, host) in [("youtu.be", "huya.com"), ("huya.tv", "ytimg.com")] {
        let source = try resolvedMihomoSource(metadata: [
            "sniffHost": sniffHost, "host": host, "processPath": resolverChromePath
        ])
        #expect(source.siteName == nil)
        #expect(source.displayName == "Google Chrome（Clash）")
        #expect(source.appIdentity?.key == "app:/Applications/Google Chrome.app")
    }
}

@Test func mihomoResolverNeverFallsBackToHostForUnrecognizedNonemptySniffHost() throws {
    for sniffHost in ["example.test", " ", "\n", "youtube.com.evil", "https://youtube.com",
                      "youtube.com..", String(repeating: "a", count: 255)] {
        let source = try resolvedMihomoSource(metadata: [
            "sniffHost": sniffHost, "host": "youtube.com", "processPath": resolverChromePath
        ])
        #expect(source.siteName == nil)
        #expect(source.displayName == "Google Chrome（Clash）")
        #expect(source.appIdentity?.key == "app:/Applications/Google Chrome.app")
        let unknown = try resolvedMihomoSource(metadata: ["sniffHost": sniffHost, "host": "youtu.be"])
        #expect(unknown.siteName == nil)
        #expect(unknown.appIdentity == nil)
        #expect(unknown.displayName == "来源应用未确认（Clash）")
    }
}

@Test func mihomoResolverKeepsAllAPIChainsLabeledAsClashIncludingDirect() throws {
    for chains in [[], ["DIRECT"], ["REJECT"], ["Proxy A", "Auto"], ["DIRECT", "Fallback"]] {
        let source = try resolvedMihomoSource(metadata: ["processPath": resolverChromePath], chains: chains)
        #expect(source.displayName == "Google Chrome（Clash）")
        #expect(source.viaClash == true)
        #expect(source.siteName == nil)
    }
}

@Test func mihomoResolverGroupsAppHelpersUsingExistingPathIdentity() throws {
    let root = "/Applications/FlowQuota Resolver Fixture.app"
    let executable = root + "/Contents/MacOS/Fixture"
    let helper = root + "/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
    let app = try resolvedMihomoSource(metadata: ["processPath": executable, "host": "youtu.be"])
    let nested = try resolvedMihomoSource(metadata: ["processPath": helper, "host": "i.ytimg.com"])
    #expect(app.appIdentity?.key == "app:" + root)
    #expect(nested.appIdentity == app.appIdentity)
    #expect(nested.id == app.id)
}

@Test func mihomoResolverDoesNotMergeSameBasenameAtDifferentPaths() throws {
    let first = try resolvedMihomoSource(metadata: ["processPath": "/opt/flowquota-fixture-a/worker"])
    let second = try resolvedMihomoSource(metadata: ["processPath": "/opt/flowquota-fixture-b/worker"])
    #expect(first.displayName == second.displayName)
    #expect(first.id != second.id)
    #expect(first.appIdentity?.key == "exec:/opt/flowquota-fixture-a/worker")
    #expect(second.appIdentity?.key == "exec:/opt/flowquota-fixture-b/worker")
}

@Test func mihomoResolverUsesStableSiteAndPathKeysWithoutRawHostOrConnectionID() throws {
    let youtube = try resolvedMihomoSource(metadata: ["processPath": resolverChromePath, "host": "youtube.com"])
    let cdn = try resolvedMihomoSource(metadata: ["processPath": resolverChromePath, "host": "rr1.googlevideo.com"],
                                    chains: ["DIRECT"], connectionID: "other", upload: 999, download: 1)
    let huya = try resolvedMihomoSource(metadata: ["processPath": resolverChromePath, "host": "huya.tv"])
    let app = try resolvedMihomoSource(metadata: ["processPath": resolverChromePath])
    let otherApp = try resolvedMihomoSource(metadata: ["processPath": "/opt/flowquota-fixture/worker", "host": "youtu.be"])
    #expect(youtube.id == cdn.id)
    #expect(youtube.id != huya.id)
    #expect(youtube.id != app.id)
    #expect(youtube.id != otherApp.id)
    #expect(!cdn.id.contains("googlevideo.com"))
    #expect(cdn.appIdentity == youtube.appIdentity)
}

@Test func mihomoResolverProcessOnlyNamesNeverBecomeIdentities() throws {
    let chrome = try resolvedMihomoSource(metadata: ["process": "  Google Chrome  "])
    let other = try resolvedMihomoSource(metadata: ["process": "Other Browser", "host": "example.test"])
    let unnamed = try resolvedMihomoSource()
    #expect(chrome.displayName == "来源应用未确认（Clash）")
    #expect(other.displayName == chrome.displayName)
    #expect(chrome.appIdentity == nil)
    #expect(chrome.id == other.id)
    #expect(other.id == unnamed.id)
    #expect(unnamed.displayName == "来源应用未确认（Clash）")
    #expect(unnamed.viaClash == true)
    let site = try resolvedMihomoSource(metadata: ["process": "Google Chrome", "host": "youtu.be"])
    #expect(site.appIdentity == nil)
    #expect(site.displayName == "YouTube（Clash）")
    #expect(site.id != chrome.id)
    #expect(try resolvedMihomoSource(metadata: ["host": "youtube.com"]).id == site.id)
}

@Test func mihomoResolverDoesNotBlameKnownProxyCoreAsOriginalApp() throws {
    let unknown = try resolvedMihomoSource()
    let core = try resolvedMihomoSource(metadata: ["processPath": resolverProxyPath, "process": "verge-mihomo"])
    #expect(core.appIdentity == nil)
    #expect(core.id == unknown.id)
    #expect(core.displayName == "来源应用未确认（Clash）")
    let site = try resolvedMihomoSource(metadata: ["processPath": resolverProxyPath, "host": "huya.com"])
    #expect(site.appIdentity == nil)
    #expect(site.siteName == "虎牙直播")
    #expect(site.displayName == "虎牙直播（Clash）")
    #expect(site.id == (try resolvedMihomoSource(metadata: ["host": "huya.tv"])).id)
    // A lookalike basename is not evidence of the allowlisted shared proxy role.
    let lookalike = try resolvedMihomoSource(metadata: ["processPath": "/opt/flowquota-fixture/verge-mihomo"])
    #expect(lookalike.appIdentity?.key == "exec:/opt/flowquota-fixture/verge-mihomo")
}

@Test func mihomoResolverRejectsInvalidAndOversizedPaths() throws {
    let unknown = try resolvedMihomoSource()
    for path in ["", "Google Chrome", "relative/worker", "/", "/tmp/..", "/tmp/.",
                 "/opt/..", "/opt/flowquota-fixture/.", "/opt/flowquota-fixture/..", "/tmp/worker/",
                 "/tmp/work\0er", "/tmp/work\ner", "/" + String(repeating: "a", count: 4_096)] {
        let source = try resolvedMihomoSource(metadata: ["processPath": path, "process": "Google Chrome"])
        #expect(source.appIdentity == nil)
        #expect(source.id == unknown.id)
        #expect(source.displayName == "来源应用未确认（Clash）")
    }
    let normalized = try resolvedMihomoSource(metadata: ["processPath": "/opt/flowquota-fixture/a/../worker"])
    #expect(normalized.appIdentity?.key == "exec:/opt/flowquota-fixture/worker")
}

@Test func mihomoResolverIgnoresProcessNamesAndBoundsHostLabels() throws {
    for name in ["", " \n ", "worker\0other", "worker\nother", String(repeating: "a", count: 257)] {
        #expect(try resolvedMihomoSource(metadata: ["process": name]).displayName == "来源应用未确认（Clash）")
    }
    let label = String(repeating: "a", count: 63)
    let maximumHost = [label, label, label, String(repeating: "b", count: 49), "youtube", "com"].joined(separator: ".")
    #expect(maximumHost.utf8.count == 253)
    #expect(try resolvedMihomoSource(metadata: ["host": maximumHost + "."]).siteName == "YouTube")
    for host in [String(repeating: "a", count: 64) + ".youtube.com", "b" + maximumHost,
                 String(repeating: "x", count: 10_000) + ".youtube.com"] {
        #expect(try resolvedMihomoSource(metadata: ["host": host]).siteName == nil)
    }
}

@Test func mihomoResolverSourceTemplatesDoNotCopyCumulativeCounters() throws {
    let source = try resolvedMihomoSource(metadata: ["host": "youtu.be"], upload: 9_000, download: 8_000)
    #expect(source.connectionCount == 0)
    #expect(source.uploadedBytes == 0)
    #expect(source.downloadedBytes == 0)
}
