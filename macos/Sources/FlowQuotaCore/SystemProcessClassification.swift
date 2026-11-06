/// Display-only interpretation of an existing identity; never a traffic attribution or rule key.
public struct SystemProcessClassification: Equatable, Sendable {
    public enum Category: String, Sendable {
        case wallpaper
        case sharedDownload
        case sharedProxy
        case application
        case unconfirmed
    }

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
                "Clash 代理内核（来源应用待确认）",
                "保留全部代理进程用量；原始应用未完全确认。Clash 识别来源是其中的辅助线索，不与内核用量再次相加；进程观测与接口可能存在时间或重复计量差异。",
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
