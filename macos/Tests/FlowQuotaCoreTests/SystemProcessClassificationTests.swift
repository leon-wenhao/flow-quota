import XCTest
@testable import FlowQuotaCore

final class SystemProcessClassificationTests: XCTestCase {
    private let agent = "/System/Library/CoreServices/WallpaperAgent.app"
    private let aerial = "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/MacOS/WallpaperAerialsExtension"
    private let settings = "/System/Library/ExtensionKit/Extensions/Wallpaper.appex/Contents/MacOS/Wallpaper"
    private let download = "/usr/libexec/nsurlsessiond"

    func testExactWallpaperAllowlist() {
        let examples = [
            ("app:" + agent, "系统壁纸代理"),
            ("exec:" + agent + "/Contents/MacOS/WallpaperAgent", "系统壁纸代理"),
            ("exec:" + aerial, "系统航拍壁纸组件"),
            ("exec:" + settings, "系统壁纸设置"),
        ]
        for (key, name) in examples {
            let identity = AppIdentity(key: key, name: "untrusted display name")
            let result = SystemProcessClassification(identity: identity)
            XCTAssertEqual(result.category, .wallpaper, key)
            XCTAssertEqual(result.displayName, name, key)
            XCTAssertTrue(result.detail.contains("不能据此确认"), key)
            XCTAssertEqual(result.identity, identity, key)
        }
    }

    func testBasenamesAndClaimedNamesAreNotEvidence() {
        for key in [
            "exec:/tmp/WallpaperAgent",
            "exec:" + agent,
            "exec:/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex",
            "exec:/Users/example/WallpaperAerialsExtension",
            "exec:/usr/local/libexec/nsurlsessiond",
            "exec:/tmp/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent",
            "exec:/System/Library/ExtensionKit/Extensions/FakeWallpaper.appex/Contents/MacOS/Wallpaper",
            "exec:/System/Library/Unknown/wallpaper",
            "exec:/System/Library/UserEventPlugins/com.apple.nsurlsessiond.plugin/Contents/MacOS/com.apple.nsurlsessiond",
            "exec:/System/Library/Frameworks/CFNetwork.framework/Versions/A/Support/nsurlsessiond",
        ] {
            let identity = AppIdentity(key: key, name: "Apple 系统壁纸 nsurlsessiond")
            let result = SystemProcessClassification(identity: identity)
            XCTAssertEqual(result.category, .unconfirmed, key)
            XCTAssertEqual(result.displayName, identity.name, key)
            XCTAssertEqual(result.identity, identity, key)
        }
    }

    func testPathVariantsNeverBroadenAllowlist() {
        for path in [aerial, settings, download, agent + "/Contents/MacOS/WallpaperAgent"] {
            let variants = [
                path + ".copy", path + "/child", path + "/", path + " ",
                path.replacingOccurrences(of: "/System/", with: "/system/"),
                path.replacingOccurrences(of: "/usr/", with: "/USR/"),
                path.replacingOccurrences(of: "/Library/", with: "/Library/../Library/"),
                path.replacingOccurrences(of: "/libexec/", with: "/libexec/./"),
                "/tmp" + path, "/" + path,
            ]
            for variant in variants where variant != path {
                let result = SystemProcessClassification(identity: AppIdentity(key: "exec:" + variant, name: "copy"))
                XCTAssertEqual(result.category, .unconfirmed, variant)
                XCTAssertEqual(result.identity.key, "exec:" + variant)
            }
            let wrongKind = SystemProcessClassification(identity: AppIdentity(key: "app:" + path, name: "copy"))
            XCTAssertEqual(wrongKind.category, .unconfirmed, path)
        }
        let renamedBundle = SystemProcessClassification(identity: AppIdentity(key: "app:" + agent + ".copy.app", name: "WallpaperAgent"))
        XCTAssertEqual(renamedBundle.category, .application)
    }

    func testSharedDownloadNeverClaimsAnOriginatingApp() {
        let identity = AppIdentity(key: "exec:" + download, name: "Wallpaper")
        let result = SystemProcessClassification(identity: identity)
        XCTAssertEqual(result.category, .sharedDownload)
        XCTAssertEqual(result.displayName, "系统共享下载服务（nsurlsessiond）")
        XCTAssertTrue(result.detail.contains("可上传或下载"))
        XCTAssertTrue(result.detail.contains("来源应用未确认"))
        XCTAssertTrue(result.detail.contains("用途未确认"))
        XCTAssertTrue(result.detail.contains("不能据此归为壁纸下载"))
        XCTAssertEqual(result.identity, identity)
        XCTAssertNotEqual(result.identity.key, "app:" + agent)
    }

    func testUnobservedIdleAssetsDaemonRemainsUnconfirmed() {
        let identity = AppIdentity(
            key: "exec:/System/Library/PrivateFrameworks/IdleScreenServices.framework/Versions/A/idleassetsd",
            name: "idleassetsd"
        )
        let result = SystemProcessClassification(identity: identity)
        XCTAssertEqual(result.category, .unconfirmed)
        XCTAssertTrue(result.detail.contains("来源应用及连接用途未确认"))
        XCTAssertEqual(result.identity, identity)
    }

    func testApplicationAndUnknownIdentitiesRetainOriginalKeysAndNames() {
        let examples: [(String, SystemProcessClassification.Category)] = [
            ("app:/Applications/Wallpaper.app", .application),
            ("app:/Applications/nsurlsessiond.app", .application),
            ("app:/tmp" + agent, .application),
            ("app:" + agent + "/", .unconfirmed),
            ("app:relative.app", .unconfirmed),
            ("exec:/tmp/Cafe\u{301}", .unconfirmed),
            ("exec:/usr/libexec/other", .unconfirmed),
            ("nsurlsessiond", .unconfirmed),
            ("", .unconfirmed),
        ]
        for (key, category) in examples {
            let identity = AppIdentity(key: key, name: "原名 Cafe\u{301}")
            let result = SystemProcessClassification(identity: identity)
            XCTAssertEqual(result.category, category, key)
            XCTAssertEqual(result.displayName, identity.name, key)
            // Compare UTF-8 as Swift String equality allows canonical Unicode equivalence.
            XCTAssertEqual(Array(result.identity.key.utf8), Array(identity.key.utf8), key)
            XCTAssertEqual(Array(result.identity.name.utf8), Array(identity.name.utf8), key)
        }
    }

    func testSameCategoryDoesNotMergeIdentities() {
        let identities = [
            AppIdentity(key: "app:" + agent, name: "WallpaperAgent"),
            AppIdentity(key: "exec:" + aerial, name: "WallpaperAerialsExtension"),
            AppIdentity(key: "exec:" + settings, name: "Wallpaper"),
            AppIdentity(key: "exec:" + download, name: "nsurlsessiond"),
        ]
        let results = identities.map { SystemProcessClassification(identity: $0) }
        XCTAssertEqual(results.map(\.identity), identities)
        XCTAssertEqual(Set(results.map { $0.identity.key }).count, identities.count)
    }
    func testVerifiedProxyCoreIsSharedAndKeepsOriginalIdentity() {
        let path = "/Library/Application Support/clash-verge-service/cores/verge-mihomo"
        let identity = AppIdentity(key: "exec:" + path, name: "verge-mihomo")
        let result = SystemProcessClassification(identity: identity)
        XCTAssertEqual(result.category, .sharedProxy)
        XCTAssertEqual(result.displayName, "Clash 代理内核（来源应用待确认）")
        XCTAssertTrue(result.detail.contains("原始应用未完全确认"))
        XCTAssertTrue(result.detail.contains("重复计量"))
        XCTAssertTrue(result.detail.contains("不与内核用量再次相加"))
        XCTAssertEqual(result.identity, identity)
        for key in ["exec:/tmp/verge-mihomo", "exec:" + path + ".copy",
                    "exec:" + path + "/", "app:" + path, "exec:/usr/local/bin/mihomo"] {
            XCTAssertEqual(SystemProcessClassification(identity: AppIdentity(key: key, name: "Clash"))
                .category, .unconfirmed, key)
        }
        let ui = AppIdentity(key: "app:/Applications/Clash Verge.app", name: "Clash Verge")
        XCTAssertEqual(SystemProcessClassification(identity: ui).category, .application)
        XCTAssertNotEqual(result.identity.key, ui.key)
    }

}
