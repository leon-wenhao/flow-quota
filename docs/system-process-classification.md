# 系统进程展示分类

> 当前流量口径（2026-11-06）：以 [流量总量与应用来源](traffic-accounting.md) 为准。主图完整显示接口用量，保留代理内核及全部已观测进程，Clash 辅助线索单列，未识别／计量差额直接说明。下文早期验收中的隐藏内核、前十合并或应用合计主图是历史实现，不再适用。

核对日期：2026-11-05。只增加 FlowQuotaCore 的展示层结果与测试，不接入采样、不改 identity key、数据库、账本、额度或规则，也不改变现有应用分组。

## 公共 API 与调用边界

```swift
let result = SystemProcessClassification(identity: identity)
// result.displayName、result.detail、result.category、result.identity
```

输入是现有 `AppIdentity`，结果中的 `identity` 原样保留输入的 key 和 name。`SystemProcessClassification.Category` 仅含 `wallpaper`、`sharedDownload`、`application`、`unconfirmed`。类别只用于展示；下游规则编辑、记账仍使用 `result.identity.key`，不能使用 displayName/category 作为合并键。

分类器是同步纯值转换，无 I/O、无额外依赖或权限要求，可用于任意线程。依赖现有 `AppIdentity`、Swift 标准库 `String`、`Equatable` 和 `Sendable`；不依赖 Foundation、AppKit、NetworkExtension、私有 framework API 或 URLSession 运行时。

系统组件严格比较完整 key，包含 `exec:` / `app:` 类型前缀；不使用 basename、名称、bundle ID 字符串或 `contains("wallpaper")` 推断。分类器不解析符号链接、不标准化路径、不忽略大小写、不移除尾部斜杠或空格。身份解析与路径可信度由现有平台层负责；本层的白名单不是代码签名验证，也不能认证任意调用方提交的字符串。

未命中白名单时，仅将以 `app:/` 开头且以 `.app` 结尾的 key 展示为 application；这只是沿用已有应用分组，不确认 Apple 身份或连接用途。其他输入保留原名并标为 unconfirmed，包括未知 `/System/Library` 路径，不因系统目录前缀一概认定职责。

## 本机证据与精确白名单

只读检查环境：macOS 27.2（26B123），arm64，Apple Swift 6.4.2（swiftlang-6.4.2.1.9），Command Line Tools macOS SDK 27.2。项目 Package.swift 声明 Swift tools 6.0、最低 macOS 14；不将本机系统组件布局推定为所有受支持版本的固定布局。

| 可执行路径（完整绝对路径） | 本机 plist 证据 | 展示分类 |
| --- | --- | --- |
| `/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent` | 同一 app 的 `Contents/Info.plist`：`CFBundleExecutable=WallpaperAgent`、`CFBundleIdentifier=com.apple.wallpaper.agent`；`/System/Library/LaunchAgents/com.apple.wallpaper.plist` 的 `Program` 同指该文件 | wallpaper：系统壁纸代理 |
| `/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/MacOS/WallpaperAerialsExtension` | 同一 appex 的 `Contents/Info.plist`：`CFBundleExecutable=WallpaperAerialsExtension`、`CFBundleIdentifier=com.apple.wallpaper.extension.aerials`、`EXExtensionPointIdentifier=com.apple.wallpaper` | wallpaper：系统航拍壁纸组件 |
| `/System/Library/ExtensionKit/Extensions/Wallpaper.appex/Contents/MacOS/Wallpaper` | 同一 appex 的 `Contents/Info.plist`：`CFBundleExecutable=Wallpaper`、`CFBundleIdentifier=com.apple.Wallpaper-Settings.extension`、`EXExtensionPointIdentifier=com.apple.Settings.extension.ui` | wallpaper：系统壁纸设置 |
| `/usr/libexec/nsurlsessiond` | `/System/Library/LaunchAgents/com.apple.nsurlsessiond.plist` 的 `Program` 及 `/System/Library/LaunchDaemons/com.apple.nsurlsessiond.plist` 的 `ProgramArguments[0]` 均指向该文件；后者另有 `--privileged` 参数 | sharedDownload：系统共享下载服务（nsurlsessiond） |

四个可执行文件均已检查存在且可执行；没有执行这些程序。前三行各接受对应完整可执行路径的 `exec:` key；WallpaperAgent 另外接受现有 resolver 实际产生的 `app:/System/Library/CoreServices/WallpaperAgent.app`。其余 bundle 根路径、辅助进程或同目录新组件不自动继承白名单。

本机存在 `/System/Library/UserEventPlugins/com.apple.nsurlsessiond.plugin/Contents/MacOS/com.apple.nsurlsessiond`，其 bundle ID 为 `com.apple.com-apple-nsurlsessiond`。它不是启动配置指向的 nsurlsessiond 可执行文件，未列入共享下载白名单。不能仅因名称包含 nsurlsessiond 认定它承担相同连接职责。

只读枚举 `/System/Library`（含隐藏项）未找到 idleassetsd；额外遍历 CoreServices、ExtensionKit、PrivateFrameworks 也未发现含 idleasset 名称的文件或目录。`/System/Library/PrivateFrameworks/IdleScreenServices.framework/Versions/A/idleassetsd`、该 framework 的 `Versions/A/Resources/Info.plist`、`/System/Library/LaunchDaemons/com.apple.idleassetsd.plist` 及 `/System/Library/Frameworks/CFNetwork.framework/Versions/A/Support/nsurlsessiond` 在本机均不存在。因此这些路径不进入白名单；idleassetsd 保持 unconfirmed。这不证明其他 macOS 版本不存在这些组件。后续扩展必须先记录对应系统的真实可执行文件和职责证据，再逐项加入。

## 官方职责依据与归因限制

- 本机 Apple 手册 `/usr/share/man/man8/nsurlsessiond.8` 将其描述为执行后台 NSURLSession 任务的每用户守护进程，并要求不要手动启动。此次仅阅读手册和启动 plist，未启动守护进程。
- 官方 macOS SDK 27.2 的 `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSURLSession.h`，第 1278–1297 行的 `backgroundSessionConfigurationWithIdentifier:` 注释说明后台上传/下载交由系统的独立进程执行，声明最低 macOS 10.10。这是理解共享后台传输角色的依据，分类器不调用此 API，也没有创建 URLSession 或下载任务。
- URLSession 的独立进程说明不能单独证明具体守护进程名称，需结合本机 nsurlsessiond 手册与 launch plist。壁纸组件职责来自上表真实路径及 plist 关联，不调用私有 framework，不把组件名称解释为每条连接的业务证明。

`wallpaper` 只确认已识别组件与壁纸有关，不确认正在下载壁纸，不确认所有连接都是壁纸、航拍资源或屏保。`sharedDownload` 表示后台传输组件（可能上传或下载），不是已证明正在下载；文案明确“来源应用未确认，用途未确认，不能据此归为壁纸下载”。现有 AppIdentity 没有共享任务的原始调用方证据，不能把 nsurlsessiond 流量合并到 WallpaperAgent、浏览器或其他应用。多个 wallpaper 组件仍保留各自 identity 和账本/规则边界。

## 验证与剩余限制

测试文件覆盖全部白名单 key、名称伪装、用户目录/假系统目录、同名插件、未知系统路径、大小写/后缀/斜杠/空格/点路径变体、错误 identity 类型、idleassetsd 保守回退、共享来源未知文案、原始 key/name 的 UTF-8 保留，以及同类结果不合并 identity。

本次只对新增 Swift 文件运行前端语法解析，并检查改动范围与文件行数；未运行共享构建脚本、SwiftPM 测试、打包或签名。测试执行、Swift 6 类型检查及集成验证由主任务统一完成。生产文件小于 300 行。

未触发壁纸资源下载，未读取真实流量，未启动 nettop，未做热点实验。未测量实际连接用途、共享服务的原应用、系统版本间布局或流量归因误差；本次结果不代表这些能力已经验证。白名单是本次核对的保守集合，不承诺涵盖所有壁纸相关进程。

## 共享代理补充（2026-11-05）

本机 `ps` 的 UID／可执行路径及公开 `proc_pidpath` 共同确认 root 运行 `/Library/Application Support/clash-verge-service/cores/verge-mihomo`，当前系统代理指向 `127.0.0.1:7897`。仅完整 `exec:` key 进入 sharedProxy 分类，当前友好名为“Clash 代理内核（来源应用待确认）”；仍保留原始身份，不合并到普通用户的 Clash Verge 界面。此分类不是签名认证，也不确认每条连接用途或原始请求方。其他路径不因包含 clash／mihomo 名称而继承分类。

文案明确共享代理、来源应用未知、与其他归因可能重叠，不与接口总量相加。新增测试检查精确路径、错误 key 类型、相似路径拒绝、原始身份保留和界面身份独立。公开进程身份修复、只读证据和未实测边界见 `vpn-attribution.md`。此前“本次未运行共享测试”的记录指壁纸分类初始阶段；本轮完整测试见 `implementation-status.md`。
