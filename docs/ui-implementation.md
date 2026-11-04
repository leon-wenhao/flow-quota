# macOS 原生 UI 实现与交接

日期：2026-11-04。本说明描述原生界面的职责、服务接口和验证范围；总体进度见 `implementation-status.md`。

## 环境与入口

- Swift Package executable：`FlowQuota`，target：`FlowQuotaApp`。
- Swift tools 6.0 / Swift 6 language mode，最低 macOS 14；本机编译为 Xcode 27.2、Swift 6.4.2、macOS SDK 27.2、arm64。
- `FlowQuotaApp.swift` 使用 `MenuBarExtra` 的 `.window` 样式，系统字体、SF Symbols、原生材质与控件。没有 Web UI 或额外依赖。
- 面板通常宽 420 pt、高至多 680 pt，并按当前屏幕可见区域缩小；内容使用原生 ScrollView。图标与文字共同表达状态，不只依赖颜色。
- `LSUIElement`、app bundle、开发签名和后台服务 plist 均由完整 app 打包脚本提供。UI 不设置 NetworkExtension entitlement，不安装过滤扩展。
- 在完整 app 的 executable 参数中添加 `--window`，可打开同一 SwiftUI 面板的普通 NSWindow，便于原生检查。关闭该窗口不退出服务。

独立 UI 编译可使用不同 scratch：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path macos --product FlowQuota --scratch-path .artifacts/ui
```

完整开发包入口为 `scripts/build-macos.sh`，arm64 app 预期路径为 `.artifacts/arm64/Flow Quota.app`。

## 文件职责

| 文件 | 职责 |
| --- | --- |
| FlowQuotaApp.swift | 菜单栏／Settings scene、共享 UI state、可选普通窗口、退出代理 |
| AppState.swift | AgentClient 调用、快照有效性、UI 权限、单一操作队列、ACK 与错误状态 |
| PanelActivityReader.swift | 观察原生窗口的 key/occlusion/关闭事件，控制面板刷新任务 |
| PanelView.swift | 面板导航、网络信息、汇总、应用列表与底部入口 |
| ApplicationRow.swift | 可复用的应用用量、每日上限、进度与文本状态 |
| QuotaEditor.swift | 正数 MB/GB 输入、1–99% 提醒阈值、版本检查及 ACK 保存 |
| ProtectionBanner.swift | 保护就绪提示、显式启用服务、连接／操作反馈 |
| UsageFormatter.swift | 字节显示、溢出安全求和、Core DecimalBytes 的本地化输入适配 |
| NotificationPermission.swift | 独立的 UserNotifications 授权状态、显式请求与可复用权限界面 |
| SettingsView.swift | 菜单栏文字偏好、真实开机启动状态、服务修复、通知设置 |
| SetupView.swift | 首次本地隐私说明、服务／扩展要求、通知授权、开机启动引导 |

所有手写源文件均小于 300 行。

## 真实状态与服务边界

1. 初始快照为 nil、应用列表为空、用量为“未知”。没有示例流量、伪造应用或 UI 自建账本。
2. 快照必须来自当前本地日期、时间在允许范围内且组件 `.ready`，才展示已归因用量。过期、断连、负数、日期或 appKey 不匹配、合计溢出均返回未知。空列表不推断为零；服务明确返回的有效零字节才显示零。
3. 日期键复用 `FlowQuotaCore.LocalDay.key`；输入解析复用 `DecimalBytes.parse`。UI 只做十进制分隔符与显示适配。未接受的额度输入不会被静默四舍五入。
4. 面板激活时串行轮询，每次请求结束后等待 3 秒；离开 key window、隐藏或关闭面板时取消所属 SwiftUI task。取消后不接受结果、不继续请求。父客户端当前 XPC await 不会立即因取消而失效，但单个请求有 5 秒超时，因此底层在途调用最多继续至该期限。操作完成后的确认刷新独立于面板生命周期。
5. 快照另有一个被替换即取消的本地过期 timer，最多保持 15 秒，并在日界失效；面板收起后不会无限保留看似新鲜的菜单栏数值。timer 不调用服务。
6. `canConfigureNetwork` 只要求服务连通、数据新鲜且没有未完成操作；`canEdit` 另要求 `.ready`。因此未安装过滤扩展仍可标记热点，但不能保存额度。
7. 当前父模块契约中，`.hotspot` 表示当前路径的手动标记；`isExpensive` 只保留 `.unknown` 候选与服务说明。UI 不把高成本网络当作已确认手机热点，不自行持久化网络标记。每次刷新以服务状态覆盖标记，路径变化可使其失效。
8. 服务返回 `.ready` 时仅显示“服务报告：保护组件已就绪”。当前模型没有逐应用阻断 ACK／活动保护字段，所以到达上限显示“阻断结果待服务确认”，不宣称真实阻断。
9. 启用、修复、热点标记与保存都通过 AppState 的单一 busy 操作入口。连接失败与操作失败分别保存；成功刷新只清除连接错误，不抹去保存／注册错误。

## 用户操作

- **启用本地服务**：只在明确点击后调用 `enableAgent()`，随后读取快照；系统批准和注册错误显示给用户，启动时不自动注册。
- **修复开发服务**：仅在 bundle 的 `FlowQuotaDevelopmentBuild` 为 true 时展示设置按钮，点击后调用 `repairDevelopmentAgent()` 并刷新。UI 不自行注销服务；是否允许修复由平台验证开发标记及无嵌入 SystemExtensions 等条件。不会自动修复或重启。
- **额度保存**：默认不限额，提醒默认 80%；有上限时必须是正数并精确到整数 byte。已有规则版本加 1，无旧规则从 1 开始；Int64.max 不可继续加。提交前再次比较当前快照版本，旧编辑页需要重开。只在 saveRule 返回 ACK 后显示确认并返回列表；失败保留输入和原规则。
- **开机启动**：直接读取 `SMAppService.mainApp.status`。用户点击才 register/unregister；错误保留，并在系统状态需要批准时引导系统登录项设置。命令行裸二进制禁用注册操作。系统注册状态与保护就绪状态互相独立。
- **本地通知**：独立 `NotificationPermission` 异步读取 `UNUserNotificationCenter.notificationSettings()`，显示授权、提醒和声音状态。只有点击“允许额度提醒”才调用 `requestAuthorization(options: [.alert, .sound])`，随后重新读取系统设置。不请求 badge，不自动弹权限，不发送测试通知。拒绝后指向系统设置中的通知页面；没有 app 身份的裸二进制不访问通知中心、不假装授权成功。窗口重新激活、进入权限界面或点击刷新时重新读取。实际额度通知的内容、去重及发送仍属于服务。
- **退出并停止保护**：菜单按钮与 Cmd-Q／系统退出均经过 AppDelegate。曾成功读取服务快照后，必须等 `stopProtection()` ACK 才允许退出；失败保持应用并显示原生错误对话框。尚未连接过服务且没有未完成操作时可以直接退出。失败的注册／修复不记作已连接会话，避免没有服务或过滤器时陷入退出等待。当前开发服务的 stop ACK 含义由父模块限定为没有已注册过滤器，不等于真实引擎停止验收。

UI 偏好只保存“菜单栏用量文字”和“已阅读首次说明”，不直接写规则数据库。

## 官方依据与适用版本

实现前核对项目 Swift 6 / macOS 14 下限，并阅读本机 Xcode 27.2 SDK 接口及官方声明：

- Apple `MenuBarExtra` 与 `WindowMenuBarExtraStyle`：https://developer.apple.com/documentation/swiftui/menubarextra
- Apple `SMAppService`：https://developer.apple.com/documentation/servicemanagement/smappservice
- Apple `UNUserNotificationCenter`：https://developer.apple.com/documentation/usernotifications/unusernotificationcenter
- Apple 通知授权请求：https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:)
- Apple `NWPath.isExpensive`：https://developer.apple.com/documentation/network/nwpath/isexpensive
- Apple `NSApplicationDelegate.applicationShouldTerminate`：https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)
- Apple `ByteCountFormatter`：https://developer.apple.com/documentation/foundation/bytecountformatter

核对位置包括 SDK 的 `SMAppService.h`、`UNNotificationSettings.h`、`UNUserNotificationCenter.h` 与 SwiftUI swiftinterface。`SMAppService` 的 macOS 13 可用性满足下限；系统头明确要求 app code signing，`.enabled` 仅表示已注册／可运行。通知的 `.ephemeral` 在 macOS 不可用，本实现不引用该 case。没有使用 macOS 15 才提供的 `defaultLaunchBehavior`。API 的实际可用性通过最低 deployment target 为 macOS 14 的编译检查，不代替 macOS 14 真机验收。

## 验证与交接限制

- 本模块使用 Xcode 27.2 / Swift 6.4.2、arm64、macOS 14 deployment target 最终编译 `FlowQuota` 成功且未输出 UI 编译警告；显式修复 Task 的弱引用捕获与 Swift 6 主线程回调约束。
- 正式 `FlowQuotaAppTests` target 使用生产模块和可注入的 `AgentServiceClient` 接口验证；8 项测试覆盖本地化输入、整数边界、未知与零、求和溢出、服务失败恢复、独立网络标记权限、保存拒绝／ACK、规则版本、快照过期、停止拒绝与重试。测试替身只在测试 target，不进入生产 executable。运行 `./scripts/test-macos.sh --filter FlowQuotaAppTests` 可复现。
- 完整回归共 64 项：Core 29、Store 17、Platform 10、App 8；实际输出保存在 `.artifacts/test-results.log`，总体记录见 `implementation-status.md`。
- 完整原生应用已启动并通过 AX 验证首次说明、主面板、设置、真实通知授权状态及开发服务修复按钮。屏幕截图受 ScreenCaptureKit `-3811` 限制，不宣称已完成视觉截图验收。
- 本轮未自动注册登录项、启用／修复系统服务、申请通知授权或发送通知；系统批准／拒绝分支、开机启动恢复及真实额度事件送达仍待验证。
- 没有有效正式签名身份，没有安装并验证真实过滤扩展。真实流量计量、并发额度阻断、跨日与重启恢复、代理去重、停止真实引擎 ACK、正式签名／公证均不在 UI 已完成的验收结论内。UI 无权绕过这些条件。
- 还需要 macOS 14、Intel、不同屏幕尺寸／缩放、VoiceOver 和键盘完整走查。当前按原生控件、系统文字尺寸、图标＋标签及滚动布局实现，不将代码具备辅助标签等同于完整可访问性验收。
