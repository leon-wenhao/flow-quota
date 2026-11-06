/// Display-only interpretation of an existing identity; never a traffic attribution or rule key.
public struct SystemProcessClassification: Equatable, Sendable {
    public enum Category: String, Sendable {
        case wallpaper
        case sharedDownload
        case sharedProxy
        case application
        case unconfirmed
    }

    /// Shared list/chart visibility; an exact known proxy identity is diagnostic only.
    public var visibleInApplicationUsage: Bool { category != .sharedProxy }

    /// The exact input identity, including its original key and name.
    public let identity: AppIdentity
    public let displayName: String
    public let detail: String
    public let category: Category

    /// Accepts identities already resolved by the platform layer. No filesystem or network I/O.
    /// Only complete allowlisted keys establish a known component's role. They do not
    /// establish a connection's purpose or a shared service's originating application.
    public init(identity: AppIdentity) {
        self.identity = identity
        let presentation: (name: String, detail: String, category: Category)
        switch identity.key {
        case "app:/System/Library/CoreServices/WallpaperAgent.app",
             "exec:/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent":
            presentation = (
                "系统壁纸代理",
                "已识别系统壁纸组件；不能据此确认所有连接用途。",
                .wallpaper
            )
        case "exec:/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/MacOS/WallpaperAerialsExtension":
            presentation = (
                "系统航拍壁纸组件",
                "已识别系统航拍壁纸扩展；不能据此确认正在下载壁纸或所有连接用途。",
                .wallpaper
            )
        case "exec:/System/Library/ExtensionKit/Extensions/Wallpaper.appex/Contents/MacOS/Wallpaper":
            presentation = (
                "系统壁纸设置",
                "已识别系统壁纸设置扩展；不能据此确认所有连接用途。",
                .wallpaper
            )
        case "exec:/usr/libexec/nsurlsessiond":
            presentation = (
                "系统共享下载服务（nsurlsessiond）",
                "系统后台传输服务（可上传或下载）；来源应用未确认，用途未确认，不能据此归为壁纸下载。",
                .sharedDownload
            )
        case "exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo":
            presentation = (
                "Clash Verge 代理内核（Mihomo）",
                "共享代理传输；来源应用未确认，可能与其他应用归因重叠。独立展示，不与 Clash 界面进程合并，也不与接口总量相加。",
                .sharedProxy
            )
        default:
            // An app-shaped key describes grouping only, not Apple provenance or signing.
            if identity.key.hasPrefix("app:/"), identity.key.hasSuffix(".app") {
                presentation = (identity.name, "按现有应用身份展示；连接用途未确认。", .application)
            } else {
                presentation = (identity.name, "组件职责、来源应用及连接用途未确认。", .unconfirmed)
            }
        }
        displayName = presentation.name
        detail = presentation.detail
        category = presentation.category
    }
}
