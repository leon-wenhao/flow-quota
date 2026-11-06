# macOS 原生 UI 实现与交接

> 2026-11-05 独立接口总量更新（用户已批准）：顶部和菜单栏使用物理网络接口字节增量的当日累计，应用仍使用 nettop 归因，绝不相加补齐总量。应用采样与阈值提醒使用 MonitoringStatus，不使用过滤 readiness 判定。菜单隐藏时由 AppDelegate 的单个轮询任务持续刷新，UserNotifications 调度成功后才确认服务去重。规则保存只确认持久化。下文涉及阻断/保护组件的原设计保留为后续背景，当前操作见 README 和 tasks/005-reminder-monitor.md。

更新日期：2026-11-05。本说明描述原生界面的职责、服务接口和验证范围；总体进度见 `implementation-status.md`。

## 当前网络与提醒预算

服务契约中，`.expensive` 表示 `NWPath.status == .satisfied` 且 `isExpensive` 的路径并自动计量，`.hotspot` 只表示明确手动标记。二者的上传＋下载进入同一应用、当前日观测用量及提醒预算，切换不会清零或另发额度；无需 schema 变更。`.ordinary` 不自动计量，`.unknown` 表示网络状态不可用。

- `.expensive` 显示网络类型“高成本网络”，采集与接口状态独立显示；详情明确成本信号不等于已确认手机热点、设备或运营商，隐藏重复手动标记按钮。
- `.hotspot` 保留“取消手动热点标记”；普通/未知状态保留标记入口，并继续按 `canConfigureNetwork` 禁用及显示原因。断连或过期快照不能宣称自动计量已生效。
- 汇总与菜单栏可访问名称采用“今日计量接口总量”，只使用 `AgentSnapshot.interfaceUsage`。统计本机物理接口上传＋下载的连续观测增量，包含局域网流量与协议开销，不含手机自身或其他设备流量，不等于运营商账单。顶部同时显示接口服务说明、接口最近采样时间和快照时间。
- 高成本网络不设置 `hotspotMarked`。应用可用性继续依赖新鲜快照、应用采样时间及 MonitoringStatus；接口总量有独立有效性检查，不依赖应用采样或应用列表。切回普通/未知网络可保留当日接口累计，同时标明保留状态。
- 开发服务自检 `DevelopmentServiceCheck.Result` 增加 `network: NetworkState`，取自第二次有效快照的 `second.network`；沿用现有标志，仅输出状态元数据，不输出应用名称或用量。

接口汇总与应用分析分开：应用采样横幅明确标为应用采样状态，避免应用采样失败被误解为接口总量停止。应用列表标题为“应用用量分析（可能重叠）”，说明 nettop 归因中的代理重叠，不相加作为总量。应用采样时间在列表区独立显示。提醒仍按每个应用的归因用量和规则触发，不按接口总量触发；接口数据缺失不会抑制已有应用提醒。

此变更只消费 Core/Agent 新增接口字段，不新增平台采样工具、授权请求、通知事件、表或迁移。达到阈值仅提醒，规则 ACK 只表示提醒配置持久化。

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
| AppMonitor.swift | AppDelegate 持有的应用生命周期轮询，面板隐藏时继续刷新并处理提醒 |
| PanelView.swift | 面板导航、网络信息、应用分析列表与底部入口 |
| InterfaceUsageSummary.swift | 独立接口总量、保留／未知原因、接口服务说明与采样时间 |
| InterfaceUsagePresentation.swift | 接口有效性衍生状态、保留状态、菜单文字与帮助，不读取应用用量 |
| ApplicationRow.swift | 可复用的应用用量、每日上限、进度与文本状态 |
| QuotaEditor.swift | 正数 MB/GB 输入、1–99% 提醒阈值、版本检查及 ACK 保存 |
| MonitoringBanner.swift | 采样状态、覆盖限制、显式启用服务与连接／操作反馈 |
| UsageFormatter.swift | 字节显示、溢出安全求和、Core DecimalBytes 的本地化输入适配 |
| NotificationPermission.swift | 独立的 UserNotifications 授权状态、显式请求与可复用权限界面 |
| SettingsView.swift | 菜单栏文字偏好、真实开机启动状态、服务修复、通知设置 |
| SetupView.swift | 首次本地隐私说明、计量范围、采样服务与通知授权引导 |
| DevelopmentServiceCheck.swift | 开发包服务自检，输出包括网络分类的状态元数据 |

所有手写源文件均小于 300 行。

## 真实状态与服务边界

1. 初始快照为 nil、应用列表为空、用量为“未知”。没有示例流量、伪造应用或 UI 自建账本。
2. `AppState.totalUsage` 只取 `interfaceUsage.totalBytes`：服务必须已连接，快照须为当前本地日期且在既有 -5…15 秒有效范围内，接口累计日期须为今天，两个字节计数须非负且求和不溢出。缺失、断连、快照过期或日期／计数无效时返回 nil，显示“未知”，绝不回退到应用求和。合法的接口零字节可以显示，即使应用列表为空。
   - 当日合法累计不要求应用存在、`sampledAt` 存在或应用 MonitoringStatus 正常，也不因当前 `interfaceSampledAt` 缺失而丢弃服务已保留的累计。若采集暂停、非计量网络、接口采样时间缺失或不新鲜，数值邻近明确标注保留状态；菜单文字加“已保留”，帮助包含原因、接口服务说明及接口采样时间。接口时间缺失显示“尚无有效采样时间”。
   - `interfaceUsageAvailable` 只表示当日累计可展示，不保证当前接口正在采样。服务没有独立接口 readiness 枚举，应用监控为 `.failed` 或 `.unavailable` 不影响总量或将仍在更新的接口误标为保留；UI 不凭应用采样成功宣称接口工作正常；`interfaceMessage` 始终显示并作为当前接口状态依据。VPN／路由归属不明确时可能不可用，绝不伪造零。断连／过期时旧累计不作为当前值展示。
   - `knownUsage` 和应用排序沿用原逻辑：有效快照、真实应用采样、MonitoringStatus 为 `.collecting` 或 `.paused`，检查 appKey、日期、非负计数与溢出；不依赖接口字段。
3. 日期键复用 `FlowQuotaCore.LocalDay.key`；输入解析复用 `DecimalBytes.parse`。UI 只做十进制分隔符与显示适配。未接受的额度输入不会被静默四舍五入。
4. AppDelegate 持有单个 AppMonitor 串行轮询，每次请求结束后按最新本机偏好等待 1–5 秒（默认 5 秒）；设置的「通用 → 用量刷新间隔」自动保存到 UserDefaults，下一轮等待生效，不中断正在处理的通知；面板隐藏或关闭不停止刷新和提醒调度。应用退出时取消轮询，取消后的结果不继续处理；操作后的确认刷新仍由 AppState 执行。
5. 快照另有一个被替换即取消的本地过期 timer，最多保持 15 秒，并在日界失效；面板收起后不会无限保留看似新鲜的菜单栏数值。timer 不调用服务。
6. `canConfigureNetwork` 要求服务连通、数据新鲜、没有未完成操作且未在退出；`canEdit` 复用该条件，无需过滤扩展。因此采样失败或未安装扩展时仍可保存提醒配置。
7. 网络标题、详情与手动入口由 AppState 根据当前有效服务快照派生；`.expensive` 自动计量且不设置 `hotspotMarked`，`.hotspot` 表示手动标记。UI 不自行持久化网络标记，每次刷新以服务状态为准。
8. 过滤 readiness 不决定当前采样与编辑权限；接口总量不参与应用阈值判定，应用达到阈值仅显示提醒状态，不宣称保护或阻断。提醒由 Agent 提出事件，主应用在系统接受通知请求后 ACK 服务去重。
9. 启用、修复、热点标记与保存都通过 AppState 的单一 busy 操作入口。连接失败与操作失败分别保存；成功刷新只清除连接错误，不抹去保存／注册错误。

## 用户操作

- **启用本地服务**：只在明确点击后调用 `enableAgent()`，随后读取快照；系统批准和注册错误显示给用户，启动时不自动注册。
- **修复开发服务**：仅在 bundle 的 `FlowQuotaDevelopmentBuild` 为 true 时展示设置按钮，点击后调用 `repairDevelopmentAgent()` 并刷新。UI 不自行注销服务；是否允许修复由平台验证开发标记及无嵌入 SystemExtensions 等条件。不会自动修复或重启。
- **额度保存**：默认不限额，提醒默认 80%；有上限时必须是正数并精确到整数 byte。已有规则版本加 1，无旧规则从 1 开始；Int64.max 不可继续加。提交前再次比较当前快照版本，旧编辑页需要重开。只在 saveRule 返回 ACK 后显示确认并返回列表；失败保留输入和原规则。
- **开机启动**：直接读取 `SMAppService.mainApp.status`。用户点击才 register/unregister；错误保留，并在系统状态需要批准时引导系统登录项设置。命令行裸二进制禁用注册操作。系统注册状态与采样状态互相独立。
- **本地通知**：独立 `NotificationPermission` 异步读取 `UNUserNotificationCenter.notificationSettings()`，显示授权、提醒和声音状态。只有点击“允许额度提醒”才调用 `requestAuthorization(options: [.alert, .sound])`，随后重新读取系统设置。不请求 badge，不自动弹权限，不发送测试通知。拒绝后指向系统设置中的通知页面；没有 app 身份的裸二进制不访问通知中心、不假装授权成功。窗口重新激活、进入权限界面或点击刷新时重新读取。实际阈值事件由服务提出，主应用通过 ReminderDelivery 调度并确认去重；调度或 ACK 失败可见。
- **退出并停止采集**：菜单按钮与 Cmd-Q／系统退出均经过 AppDelegate。曾成功读取服务快照后，必须等 `stopProtection()` ACK 才允许退出；失败保持应用并显示原生错误对话框。尚未连接过服务且没有未完成操作时可以直接退出。失败的注册／修复不记作已连接会话，避免没有服务或过滤器时陷入退出等待。当前 stop ACK 等待采样任务停止；确认失败时可明确选择“仅退出界面”，后台采集状态未知且不再投递通知。

UI 偏好保存菜单栏用量文字、已阅读首次说明、刷新间隔及应用外观，不直接写规则数据库。

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

## 独立接口总量 UI 交接（2026-11-05，本次）

修改范围仅为 `macos/Sources/FlowQuotaApp/*`、`macos/Tests/FlowQuotaAppTests/*` 和本文件。Swift tools 6.0、最低 macOS 14 沿用 Package.swift；本次只消费 `InterfaceUsage` 和快照新增字段，复用既有 SwiftUI、Date 格式化和通知投递接口，不引入新的系统 API 或平台行为假设。官方 UI 入口仍见上述 Apple MenuBarExtra、ByteCountFormatter 文档；接口采样实现和官方行为依据由 Core/Agent/Platform 任务交付。

新增 `InterfaceUsagePresentationTests.swift` 共 12 项测试：接口 200 bytes 与应用 1000 bytes 独立、应用非零而接口缺失仍为 nil、无应用列表／应用采样失败仍可展示接口累计、跨日不符、负数与溢出、过期和过远未来快照、断连、暂停与保留标签、VPN 不可用说明及缺失接口采样时间、旧接口采样时间、合法零字节，以及接口缺失不影响应用提醒调度与 ACK。沿用测试替身，不调用真实接口、nettop、系统通知或已安装应用。

现有 AppStateTests 将“应用采样可用”与“接口总量可用”分开断言；NetworkPresentationTests 显式注入接口 fixture，接口值与应用值不同，继续覆盖自动高成本、手动热点、普通／未知网络及提醒投递。

主任务统一验证完成：App 37 项、完整回归 164 项通过，arm64/x86_64 编译和严格签名检查通过。AppState.swift 为 234 行。接口采样超过 8 秒即标注保留值，与服务过期阈值一致。测试使用替身，不调用真实计数器、nettop 或系统通知；随后已安装并打开真实 UI，检查截图、暂停/未知状态、设置、应用列表滚动及阈值编辑页；未保存测试配置，未做热点实验。真实接口、完整键盘／VoiceOver 和通知展示仍待验收；下节旧实机结果不作为本轮接口总量证据。

## 独立接口总量之前的验证记录（2026-11-05，历史）

新增 `NetworkPresentationTests.swift` 的 4 项测试，使用现有 FakeAgentClient 与 FakeReminderScheduler，覆盖 `.expensive` 自动呈现且非手动标记、已知用量与已有提醒事件调度、手动热点取消、普通/未知状态的标记回退与当日用量保留，以及过期/断连不得宣称自动计量。现有通知正文测试同时检查合并范围文字。测试替身不会发送系统通知。

`git diff --check` 及完整测试 109 项通过（Core 29、Store 27、Platform 22、App 25、Agent 6），包含全部 4 项 NetworkPresentationTests。两种架构构建与严格签名校验通过；本机安装包自检确认自动计量，原生界面确认高成本状态、标记按钮隐藏、实际应用用量非零并持续增加。未申请新权限或发送真实通知，通知横幅仍待用户验收。数值与实机证据见 implementation-status.md；以下旧结果保留为历史背景。

## 历史验证与交接限制（2026-11-04，非本次结果）

- 本模块使用 Xcode 27.2 / Swift 6.4.2、arm64、macOS 14 deployment target 最终编译 `FlowQuota` 成功且未输出 UI 编译警告；显式修复 Task 的弱引用捕获与 Swift 6 主线程回调约束。
- 正式 `FlowQuotaAppTests` target 使用生产模块和可注入的 `AgentServiceClient` 接口验证；8 项测试覆盖本地化输入、整数边界、未知与零、求和溢出、服务失败恢复、独立网络标记权限、保存拒绝／ACK、规则版本、快照过期、停止拒绝与重试。测试替身只在测试 target，不进入生产 executable。运行 `./scripts/test-macos.sh --filter FlowQuotaAppTests` 可复现。
- 完整回归共 64 项：Core 29、Store 17、Platform 10、App 8；实际输出保存在 `.artifacts/test-results.log`，总体记录见 `implementation-status.md`。
- 完整原生应用已启动并通过 AX 验证首次说明、主面板、设置、真实通知授权状态及开发服务修复按钮。屏幕截图受 ScreenCaptureKit `-3811` 限制，不宣称已完成视觉截图验收。
- 本轮未自动注册登录项、启用／修复系统服务、申请通知授权或发送通知；系统批准／拒绝分支、开机启动恢复及真实额度事件送达仍待验证。
- 没有有效正式签名身份，没有安装并验证真实过滤扩展。真实流量计量、并发额度阻断、跨日与重启恢复、代理去重、停止真实引擎 ACK、正式签名／公证均不在 UI 已完成的验收结论内。UI 无权绕过这些条件。
- 还需要 macOS 14、Intel、不同屏幕尺寸／缩放、VoiceOver 和键盘完整走查。当前按原生控件、系统文字尺寸、图标＋标签及滚动布局实现，不将代码具备辅助标签等同于完整可访问性验收。


## 后台大流量预警 UI（2026-11-05，当前）

新增设置 `TrafficAlertSettingsView` 与可复用阈值输入，`TrafficAlertDraft` 复用 DecimalBytes／QuotaInput 精确换算。三类阈值可各自关闭，窗口与冷却使用原生 Stepper；保存经 XPC 持久化确认，失败不清空输入。`TrafficAlertHistoryView` 显示当天事件、实际连续时长、原身份及系统调度状态，使用 32 条分页加载最多 256 条。面板和设置说明已更新为接口预警与应用预警独立。

`NotificationDeliveryQueue` 共享原应用每日提醒和新增事件的授权、调度、ACK 与重试；只有 OS 接受后才确认，挂起后重新检查快照、暂停和策略版本。应用采样失败允许独立接口告警继续投递。错误属性仍能通过 Observation 更新界面，有专门测试。系统友好名称仅用于展示，依据见 `system-process-classification.md`。

当前完整测试 App 48 项通过，含 ACK 重试不重复调度、拒绝／失败不 ACK、配置变更／暂停取消旧提案、保存失败、分页和状态观察。测试使用替身，不发送系统通知。新版已安装并通过真实 UI 检查：三类默认阈值、窗口／冷却、保存按钮滚动布局及空事件完整读取；服务保持暂停，未保存实验配置或请求授权。真实告警横幅验收以 implementation-status.md 最新记录为准。

## 设置页信息精简（2026-11-05）

设置页按采集状态、通用、提醒排列。采集状态保留一条摘要、主要操作和图标刷新；完整服务文字放在“采样详情”。异常与未就绪原因仍直接显示，断连、授权失败等错误继续使用原 ServiceFeedback。应用状态明确保留“应用”字样，避免暗示独立接口计量也停止。正常采集用绿色图标，暂停／等待用橙色，失败用红色；标题保持主文字颜色，状态同时由文字和图标表达。

通用项使用原生 switch，登录项沿用 SMAppService 的真实状态及注册逻辑；“未注册”显示为“未开启”。通知展示授权摘要及必要操作，渠道设置和投递限制折叠。流量预警保留原有三类阈值、输入校验、保存及 ACK 行为，说明收进“预警规则”。开发修复与系统设置入口收进“服务与诊断”，计量口径收进“计量说明”；不删除重要边界说明。SettingsSection 仅组织视觉分组，无业务状态或存储访问。

依据 Apple SwiftUI DisclosureGroup 和 SwitchToggleStyle 官方文档（文档分别标注 macOS 11、10.15 起可用），保留最低 macOS 14，无新依赖或平台权限。官方数据源为 `https://developer.apple.com/tutorials/data/documentation/swiftui/disclosuregroup.json` 与 `https://developer.apple.com/tutorials/data/documentation/swiftui/switchtogglestyle.json`，本轮已读取并核对可用性。

验证：现有 FlowQuotaAppTests 48 项通过；arm64／x86_64 原生构建及严格 ad-hoc 签名检查通过。用独立、仅含替身客户端与调度器的 NSHostingView 预览检查 420×680 pt 下的暂停、失败及深浅色布局；不启用真实采样或通知调度。预览从命令行运行，登录项／通知包身份提示不代表安装版状态，实际系统权限与通知横幅不在本次展示调整验收结论内。原生 ScrollView 的折叠内容保留滚动；完整键盘／VoiceOver 仍需另行走查。

用户授权替换后，已更新 `/Applications/Flow Quota.app` 并打开真实设置页。安装文件摘要与新 arm64 构建一致、严格签名校验通过；真实 XPC 暂停自检成功，19 项既有应用仍在，schema v4 的 8 张业务表内容摘要与替换前一致。旧应用和数据库备份及核对记录位于 `.artifacts/ui-simplify-install/`。原生界面已确认新分组、开关、未开启登录项、未授权通知及折叠说明，服务保持暂停；未请求通知授权或启用采集。

## 主面板、刷新稳定性与整行展开（2026-11-05）

主面板改为固定顶部概览、独立应用列表滚动和固定底栏。OverviewView 展示应用采集状态、网络类型、独立接口总量及简短接口状态；“用量详情”进入包含服务原始说明、采样时间和计量口径的详情页，“预警记录”进入当天事件页，通知入口进入设置。当前状态不可用时不把用量或事件计数伪装成零，暂停网络不再宣称“已自动计量”。NetworkObserver 的诊断文案同步为“采集期间自动计量”，网络计量策略未变。

ApplicationListOrder 只保存应用身份顺序，不缓存用量：首次按当前用量排列，后台刷新保持既有行位置，新来源追加、已消失来源移除；“按用量排序”显式重新排序。每行始终采用两行布局，去掉随有效用量临时出现的进度条；共享下载与代理服务仍直接注明原始请求方未确认，完整身份和归因说明留在详情。正常轮询不会清空已有快照、插入通知授权加载行或改变列表结构。刷新图标／进度使用固定 20×20 pt 区域，手动刷新不再插入业务操作提示行；设置保存仍按原有 ACK 行为执行。去除预警配置视图按 policy.version 重建的做法，版本变化只重载草稿，保留折叠状态。

FullRowDisclosureStyle 使用原生 Button 包裹箭头、标题和整行留白，仅标题行可切换；展开内容中的开关、输入和按钮保持独立。为所有 Panel 子页面统一注入该样式，按钮保留键盘操作及展开／收起的辅助说明，不为后台数值更新增加动画。应用采样展示抽到 MonitoringPresentation 与设置页复用。连接、应用采样、通知投递和预警容量异常仍直接显示；容量异常沿用现有 Agent 诊断的两个明确错误前缀，不修改服务协议或数据库。

Apple 官方 DisclosureGroupStyle／DisclosureGroupStyleConfiguration 文档分别说明可自定义外观与交互，并提供 label、content 和可修改的 isExpanded；macOS 13 起可用，低于本项目 macOS 14 下限。本轮已读取 `https://developer.apple.com/tutorials/data/documentation/swiftui/disclosuregroupstyle.json` 和 `https://developer.apple.com/tutorials/data/documentation/swiftui/disclosuregroupstyleconfiguration.json`，并以 Xcode 27.2／Swift 6.4.2／SDK 27.2 实际编译验证。NSHostingView 的模拟暂停、采集和失败布局预览在 `.artifacts/overview-ui/`，不接入 XPC、真实采样、数据库或通知调度。


本轮验证：完整回归共 231 项通过（37 项 XCTest、60 项 Store、58 项 Platform、5 项 Core、54 项 App、17 项 Agent）；嵌套展开样式最终修正后再次通过全部 54 项 App 测试。arm64／x86_64 构建及严格 ad-hoc 签名检查通过，日志位于 `.artifacts/overview-ui/`。嵌套 DisclosureGroup 的 content 显式继承 FullRowDisclosureStyle，避免只在最外层标题行生效。

用户授权后已替换并打开 `/Applications/Flow Quota.app`。真实原生界面确认首屏可见前 5 个应用，19 项既有应用可独立滚动，概览与底栏固定；滚动后刷新可见行像素位置保持稳定。设置中的通知详情、流量预警及嵌套预警规则均可点击标题留白展开，输入框操作不触发折叠，刷新保留展开状态及输入焦点。完整键盘及 VoiceOver 走查不在本次验收结论内。

安装初次使用 ditto 覆盖现有包时，SMAppService 自检出现 XPC 超时，launchctl 记录 EX_CONFIG 78、空 LWCR cdhash 与 spawn 失败。随后改为先构造并校验完整新包，再整体替换原应用包，重新登记 LaunchServices 并执行既有暂停服务修复；最终版本首次整体替换后的 XPC 自检成功，未降低签名或服务身份校验。过程与可恢复旧包保存在 `.artifacts/overview-ui-install/`。

最终核对安装包主程序、辅助程序、Info.plist 与图标摘要均匹配最终 arm64 构建，严格签名通过。数据库 schema v4、完整性检查正常，8 张业务表内容摘要与替换前一致，原应用记录、用量及设置保留。服务保持暂停，未运行 nettop，临时暂停启动环境变量已清除；未请求通知授权、保存新配置或生成实验性网络流量。未执行热点真实计量或运营商对照；结论仅覆盖本轮布局、交互、模拟回归、构建及安装核对。最终机器可读记录为 `.artifacts/overview-ui-install/final-verification.json`。


## 设置控件对齐、按钮与来源标识（2026-11-05）

三个预警 Toggle 的 label 填满剩余宽度，开关与窗口／冷却 Stepper 均统一靠右。通用设置开关沿用相同布局。SettingsActionStyle 复用原生 bordered／borderedProminent、regular 尺寸、8 pt 圆角和中等字重，保存预警靠右并突出显示，登录项、通知授权及服务工具按钮统一尺寸。按钮颜色继续尊重系统主题。依据 Apple `View.buttonBorderShape(_:)` 官方文档（macOS 12 起可用，已读取 `.artifacts/settings-polish/button-border-shape.json`），项目下限仍为 macOS 14。

应用行原先的 SF Symbol `app` 是装饰性图标，并无复选功能；为避免空心框误解，现改为带来源名称首字的浅色圆角标识。已有接近／达到阈值的警示图标及其文字仍保留，点击整行进入详情的行为未变；未增加应用图标查询、文件读取或身份匹配。

新配置在 Core 初始化和 v4 首次建表中均默认为 180 秒，范围仍为 1–15 分钟。现有 v4 配置在升级时原样读取，不改 schema，不按默认值自动覆盖已保存窗口。相关产品、数据库设计及 AGENTS 约束已同步。测试覆盖初始值、草稿转换、已有五分钟配置重开保留；旧事件替身的窗口改为读取对应初始策略，保留具体五分钟窗口的单独测试。

233 项完整回归通过（37 XCTest、61 Store、58 Platform、5 Core、55 App、17 Agent），arm64／x86_64 构建和严格 ad-hoc 签名检查通过。模拟来源渲染检查左右对齐及深浅色布局，产物在 `.artifacts/settings-polish/`，不接入采样、XPC 或通知。

已替换并打开 `/Applications/Flow Quota.app`。替换前当前正在采集，先通过原有服务暂停并备份，再替换完整包。首次登记出现 XPC 超时，launchctl 显示 EX_CONFIG 78 与空 LWCR cdhash；重新以完整签名包整体登记后服务自检恢复，未放宽签名或身份校验。原生设置页确认三个开关与两个步进控件靠右、保存按钮位于右下；按本次用户要求，通过设置页把本机窗口从 5 分钟改为 3 分钟并保存，页面收到持久化确认。仅窗口和配置版本改变，每日 1000 MB、接口／应用短时各 200 MB、冷却 10 分钟及启用状态保留；其他七张业务表逐行与备份一致，26 项应用记录与已观测用量保留。最后返回概览并确认首字标识可见。

最终安装文件摘要与构建一致、严格签名和 schema v4 完整性检查通过。采集留在暂停状态，未运行 nettop，临时暂停启动环境变量已清除；未生成热点实验流量、未申请通知授权，未开展运营商对照或全面辅助功能验收。备份、注册失败证据和最终核对记录位于 `.artifacts/settings-polish-install/`。


## 操作反馈与滚动位置稳定性（2026-11-05）

保存预警沿用 AppState.perform 的序列化操作及服务 ACK：开始时清空旧反馈、插入 operation，ACK 后写入 notice，结束时移除 operation。此前 PanelView 把 ServiceFeedback 放在设置页 ScrollView 的最前面，这三种变化会改变文档高度，尤其在接近底部时引发滚动补偿。应用每日阈值保存、启用采集、热点标记、开发服务修复及停机操作共用同一问题路径。

现将 ServiceFeedback 统一放入 PanelView 原有底栏，保留固定 24 pt 内容高度，操作和错误状态只替换该区域的图标及文字。默认显示本地保存说明，开始显示进度、服务 ACK 后显示完成，错误优先于普通完成信息。按钮的 hover 提示与可访问名称保留完整原文，点击可打开固定大小、内部可滚动的详情 popover，包含全部错误和完成信息，不把完整错误截断后丢弃。顶部和 OverviewView 不再插入同类反馈。AppState 的保存、ACK、版本校验、异常、重试与采样规则未改变。

同步检查并处理其他临时增删路径：通知授权按钮由授权状态决定是否存在，读取中仅禁用；授权等待进度占用刷新图标的固定区域，授权错误进入共用底栏。开机启动失败和预警历史加载失败也进入共用反馈，历史加载指示器保留固定位置。QuotaEditor 的不可编辑说明预留固定高度，保存期间禁用输入不再额外插入锁定行。用户主动展开、切换阈值开关或加载更多真实记录仍按内容调整高度。

Apple View.popover(isPresented:attachmentAnchor:arrowEdge:content:) 官方文档标注 macOS 10.15 起可用，本项目仍以 macOS 14 为下限；已读取官方 JSON，副本位于 `.artifacts/feedback-stability/popover.json`，并以现有 Xcode 27.2／Swift 6.4.2 实际编译验证。文档端点为 `https://developer.apple.com/tutorials/data/documentation/swiftui/view/popover(ispresented:attachmentanchor:arrowedge:content:).json`。


验证完成：239 项完整回归通过（37 XCTest、61 Store、58 Platform、5 Core、61 App、17 Agent），arm64／x86_64 构建与严格 ad-hoc 签名通过。新增原生 NSHostingView／NSScrollView 测量测试覆盖多种操作在等待、成功、长错误及清除消息时的 viewport、document frame 与 scroll offset，均与操作前完全一致；另测 QuotaEditor 保存期间及恢复后文档几何保持一致。状态机测试覆盖持久化 ACK 前不报成功、失败保留完整错误、不确认失败保存及随后重试。全部使用替身服务与调度器，没有真实采样或权限请求。

已替换并打开安装版。此次完整包替换后服务第一次自检成功；真实设置页滚动到底部后执行一次保持原值的保存，保存前后所有可见设置项及展开状态不变，固定底栏显示“预警已保存”，详情 popover 可打开并完整展示持久化说明，关闭后滚动位置不变。真实保存仅使预警配置版本 10→11，3 分钟窗口、三个启用状态、每日 1000 MB、接口／应用短时各 200 MB 与 10 分钟冷却不变。其余七张表逐行与暂停后的备份一致，27 项应用及已观测用量保留。schema v4、完整性、严格签名、安装文件与构建摘要均通过；采集保持暂停，无 nettop 运行，临时暂停启动变量已清除。证据与备份在 `.artifacts/feedback-stability-install/`，测试及官方资料在 `.artifacts/feedback-stability/`。未开启热点实验采样或真实通知授权流程，未做完整键盘／VoiceOver 走查。


## 应用详情页优化（2026-11-05）

QuotaEditor 改为三段式信息层级：顶部“用量概览”突出来源标识、来源类型、今日归因用量及上传＋下载口径；“每日提醒”只保留阈值开关、数值／单位、提前提醒百分比和保存设置；“更多信息”收纳来源身份与计量说明。原先连续的大段解释移入两个整行可展开的 DisclosureGroup，避免首屏被长文案占满。共享代理／下载服务仍明确显示“原始请求方未确认”，不把共享服务误认成具体应用。

开关、输入框、单位选择、Stepper 和保存按钮采用与设置页一致的控件尺寸和对齐，保存按钮位于每日提醒卡右下角；无阈值时直接显示“未设阈值，仍统计用量”，避免空白表单区域。用量不可用时保留“未知”，不以暂停状态伪造零值。应用来源标识抽成 ApplicationSourceMark 与列表复用，明确它是来源标识，不是复选框。

使用模拟应用身份和用量完成浅色／深色 NSHostingView 预览，实际安装版确认 Clash Verge 代理内核详情页显示三张卡片、开关靠右、保存按钮对齐、来源说明可整行展开。完整回归 239 项通过，arm64／x86_64 构建和严格 ad-hoc 签名通过。安装替换前后 schema v4 完整性及 8 张业务表保持一致，27 项应用记录和已观测用量保留；服务保持暂停，未启用真实采样或通知授权。证据与备份位于 `.artifacts/quota-editor/` 和 `.artifacts/quota-editor-install/`。


## 开机启动开关（2026-11-05）

「通用 → 开机启动」改为原生 `Toggle` 的 `.switch` 样式，与「菜单栏显示用量」保持相同尺寸和右侧对齐。绑定读取 `SMAppService.mainApp.status == .enabled`，开启／关闭仍调用既有 register／unregister；操作期间禁用，结束后重新读取系统状态，失败仍进入共用反馈，不将本地 UI 切换当作系统确认。等待系统批准、未找到应用及未知状态不允许直接切换，保留「前往设置」入口和状态说明。无需变更数据库、采样或通知语义。

官方依据：Apple SwiftUI Toggle / ToggleStyle.switch（https://developer.apple.com/documentation/swiftui/toggle 、https://developer.apple.com/documentation/swiftui/togglestyle/switch）及 SMAppService.status（https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.property）。沿用项目 Swift tools 6.0、最低 macOS 14 与既有服务 API。本次不操作真实登录项，不启动采样；按用户此前偏好，不增加交互验收，仅重建开发包并替换安装版。


## 全应用开关样式统一（2026-11-05）

二态功能统一使用 SwiftUI 原生 Toggle.switch：菜单栏用量显示、开机启动、每日应用阈值、接口每日／接口短时／应用服务短时预警、流量采集及手动热点标记。原有前六项已是 Switch；新增共享 SamplingControl，在主面板和 MonitoringBanner（设置及用量详情）使用同一状态与命令；主面板手动热点改为 Switch，高成本自动计量时仍隐藏重复标记入口。刷新、保存、权限请求、导航、连接、加载／收起记录和退出保持动作或展开语义。

采集开关开启调用既有 enableAgent，关闭调用既有 stopProtection 并刷新，不退出应用、不清空今日累计。AgentSnapshot 新增可缺失的 samplingEnabled，来自服务当前接口／应用任务是否启用；归因失败且接口仍运行时保持启用，MonitoringStatus 继续独立展示健康状态。旧版服务缺字段、断连或快照过期显示未知并保留连接操作，不猜测为关闭；等待确认期间禁用，错误沿用共用反馈。该字段只属于 IPC 快照，不落库、不新增 schema 或用户偏好。通知授权需要系统确认且应用不能在此撤销系统授权，因此仍保留明确的授权动作。

实现沿用既有 SwiftUI Toggle.switch／Binding 及服务命令，最低 macOS 14、Swift tools 6.0。关键官方来源沿用本文件「开机启动开关」及 official-references.md 的原生 UI／XPC 依据。未启用真实采样或请求通知授权。


## 两类网络统计与提醒（2026-11-05）

PanelView 顶部共享 TrafficCategorySelection 原生分段选择器，用于切换查看／编辑
热点／高成本和普通网络，不改变实际连接分类。总量、应用列表与规则、图表、
预警历史和设置同时跟随该类别；实际连接状态始终单独显示。菜单栏用量标明所选
类别，避免把保留的热点用量误认为当前普通网络的新增量。Switch 仍用于二态功能。

AppState 通过 AgentSnapshot.trafficCategories 读取分类快照；旧服务缺失普通类时
显示未知并禁用该类编辑，不借用热点数据。普通类提醒初始化关闭，热点类保持已有
配置。网络采集状态、通知权限仍独立展示；配置默认开启不表示系统已经允许通知。

QuotaEditor 和 TrafficAlertSettingsView 捕获打开时的类别，保存请求携带明确类别，
避免另一个窗口切换全局查看类别后将旧草稿保存到错误账本。预警通知标题／正文、
当天记录均显示所属类别；后台通知投递不依赖界面当前查看哪个类别。两类共用采样
任务和轮询节奏，数据与提醒规则分开。


## 饼图、直接入口及当天分时用量（2026-11-05）

OverviewView 提供可直接点击的「用量图表」快捷入口，打开独立
UsageDashboardView；「计量详情」保留状态说明及图表链接。
无需先进入详情或滚动寻找图表。页面和数据继续跟随顶部网络类别。

UsageTimelineView 位于图表页首屏，支持最近一小时／今天／当天自定义起止；
短范围以 5 分钟、长范围以 30 分钟堆叠展示上传与下载，X 轴是真实时间，Y 轴为
格式化字节。选择时段查看两方向字节、有效分钟数及增量样本数。未观测留空，
有效零量用点表示，可能只观测部分时段的说明始终显示。不将快照轮询差额当成
时间序列；数据来自服务持久化的分类分钟汇总，关闭界面后仍由服务记录。
旧服务缺字段、断连、过期、未采样、计数溢出均有独立说明。

UsagePieChart 复用 Swift Charts SectorMark 绘制环形饼图，展示今日接口上传／下载
及今日应用归因。图例显示方向／名称、字节和占比；应用前五项加「其他应用」，
以全部有效归因为分母，保留原有前八项条形排行。零量不绘制虚假扇区；同名应用
按稳定身份分色，不能被 label 合并；空数据不伪造零值。饼图和排行标明今日累计，
与上方可筛选的接口分时图区分。归因与接口总量保持独立说明。

官方依据：Apple SectorMark（https://developer.apple.com/documentation/charts/sectormark）
及 View.chartXSelection(value:)（https://developer.apple.com/documentation/swiftui/view/chartxselection(value:)）。
官方 JSON 明确二者自 macOS 14 起可用，与项目最低系统版本一致；SectorMark
建议限制扇区数量、合并尾项并仅使用正值，本实现采用最多六个扇区。
分时柱使用 RectangleMark 的显式时间与字节区间绘制堆叠矩形，避免稀疏数据的
自动柱宽覆盖未知时段；依据 https://developer.apple.com/documentation/charts/rectanglemark 。
参考副本位于 `.artifacts/sectormark-reference.json`、`.artifacts/chart-selection-reference.json`、
`.artifacts/rectangle-mark-reference.json`。
Swift tools 6.0、实际 Xcode 27.2／Swift 6.4.2；实际验证结果记录于 implementation-status.md。


## 菜单栏快速概览与独立偏好设置（2026-11-05）

菜单栏不再承载完整工作流。`PanelView` 保留类别选择、接口用量、采集开关、热点标记、通知及预警摘要，应用用量／图表和偏好设置按钮跳转到原生窗口。界面只有一个 `AppState`，后台轮询仍由 `AppDelegate` 管理；关闭面板或偏好设置不会调用停止采集。只有明确暂停及退出操作沿用原服务 ACK 路径。

`PreferencesWindowController` 按需创建并保留一个 `NSWindow`，通过 `NSHostingController` 承载 SwiftUI 内容；使用原生标题栏、关闭／最小化及 resize 样式，记忆位置和大小，再次打开复用窗口并激活。`--window` 也打开此窗口，不再创建第二个完整菜单栏面板。SwiftUI 的 `Settings` scene 已移除，避免与原生窗口形成两个设置实例；偏好设置菜单命令（⌘,）与菜单栏按钮都指向同一控制器。

`PreferencesNavigation` 仅维护页面和选中应用，不参与服务或数据库。左栏分为应用用量、用量图表、计量详情、预警设置、预警记录、通用设置和使用说明。应用列表独占内容滚动区；代理观测移至计量详情；系统通知和分类阈值从通用设置移至预警设置。网络类别切换时退出应用编辑，防止沿用另一类别的应用快照保存规则。

操作反馈仍位于固定 24 pt 底栏，通用设置及展开的预警设置均验证保存中、成功、长错误不会改变滚动视口、文档高度及底部偏移。快速概览也为采集状态、网络行、计量说明和警告预留固定高度，错误完整内容通过反馈弹窗及详情页查看。

官方依据：Apple `NSWindowController` 管理窗口，`NSWindow.StyleMask` 的 titled／resizable 提供原生窗口行为，`NSHostingController` 承载 SwiftUI 视图。项目最低 macOS 14；实现使用已有 AppKit 生命周期，不新增采样 API、数据表或网络验证。测试与构建证据见 `.artifacts/preferences-tests.log` 及两个 `preferences-build-*.log`。鼠标实际拖动仍需人工验收，桌面控制连接超时；测试仅验证原生窗口标志及移动坐标、关闭／复用行为，不宣称完成鼠标操作验收。


## 菜单栏紧凑用量（2026-11-05）

按用户要求缩短系统菜单栏状态项。文字仅显示十进制紧凑用量，如 625.7 MB
显示为 626M、1.2 GB 显示为 1.2G，最多四个 ASCII 字符；图标与文字间距为
2 pt。小于 10 个单位保留至多一位小数，更大值取整，并处理 999.5 跨单位进位。
格式化只影响菜单栏展示，采样、数据库与面板精度保留。

网络类别及“已保留”不再加入状态项文字；完整类别、单位、采集状态和计量边界
保留在悬停提示、面板及独立无障碍描述中。原有图标淡化仍表示保留或不可用，
未知用量显示 —。现有通用设置“菜单栏显示用量”关闭后只显示图标，不新增偏好。


## Clash 来源归入应用列表（2026-11-05）

普通 nettop 应用与 API 站点来源在 ApplicationListView 同一列表展示，复用 TrafficSourceRowContent，来源行如 YouTube（Clash）、虎牙直播（Clash）。右侧区分每日归因和本次代理观测，点击代理行显示上传／下载、原始应用（可确认时）及计量边界，不进入额度编辑。已确认 Mihomo 内核从普通列表隐藏；API 诊断仅放计量详情，暂停文案明确为 Flow Quota 来源采集暂停。

列表按稳定 ID 保留位置，显式排序可重排两种来源；切换网络类别同时切换 API 内存累计。站点细分不进入每日应用饼图、不改接口总量，不把浏览器日累计伪装成已剔除代理后的直连流量。原生离屏模拟预览位于 .artifacts/mihomo-attribution-list-preview.png；字段、站点分类与恢复边界见 mihomo-api.md。


本轮交付验收：完整集成回归 310 项通过；原生窗口测试同时覆盖 paused／collecting 两种假服务状态，验证可移动／resize 样式、坐标移动、关闭不更改采集、重复打开复用；快速面板紧凑尺寸和两页保存反馈几何均通过。最终本机应用为 `/Applications/Flow Quota.app`，0.1.0（build 3），签名检查通过。替换中遇到开发服务 XPC 超时，随后同仓库安装恢复完成，最终 XPC 自检为 enabled／paused（配置版本 17）。安装临时启动环境已恢复。之后检测到采样进程重新出现，保留当前运行状态；不将安装时的暂停验收当作此后的实时状态。

原数据库 schema v5 到仓库已有 v6 分时汇总迁移后，仅新增 `interface_usage_minutes`；安装暂停验收点核对既有八张表全部行内容一致，完整性 ok、外键违例 0。此窗口拆分本身未新增数据库迁移。备份与验收证据位于 `.artifacts/preferences-install/`。本轮未生成验证下载、上传或测速流量；鼠标实际拖动和 Intel 机器运行仍未验收。


## 快速面板用量前三（2026-11-05）

今日接口总量下方直接显示所选网络类别的用量前三项，完整列表仍从“应用用量”
进入。AppState.topUsageItems 复用 applicationUsageItems 的降序与稳定身份排序，
仅取有效正用量的前三项；零量、未知及过期数据不充当排名，不足三项时不伪造
内容。包含完整列表已有的 Clash 来源，不额外改变隐藏内核、分类或计量规则。
应用为今日归因，Clash 为本次服务观测，保留范围／可能重叠说明，禁止将前三项
相加作为接口总量。

TopUsageListView 复用 ApplicationRow／ClashSourceRow 及 TrafficSourceRowContent
的新 compact 展示参数，仅压缩行高和次要文案，完整列表默认样式保持原状。
每行显示名次、来源标识、名称及完整单位用量。普通应用通过现有唯一偏好窗口
直达应用详情，Clash 仍使用原来源说明 popover。面板预留三行区域，轮询／切换
类别及空状态不会反复改变弹层尺寸；总高度预算由原纯摘要的 520 pt 调整为
包含三行的 680 pt，原有固定反馈区几何检查保留。


## 分时图表悬停提示（2026-11-05）

`UsageTimelineView` 仅管理时间范围和汇总，`UsageTimelineChart` 负责绘图及悬停交互，`UsageTimelineTooltip` 负责时段详情展示。移除点击／拖动选择产生的图表下方详情、两方向汇总行和长说明；说明保留在汇总行的信息图标 help 与可访问名称。鼠标进入绘图区即显示时段、上传、下载和合计，退出绘图区或视图消失时隐藏。刷新同一时段时读取最新值；时间范围改变时清除旧定位。

使用 SwiftUI `onContinuousHover`、Swift Charts `chartOverlay`、`ChartProxy.plotFrame`、`value(atX:)` 与 `position(forX:)`，按实际 plot frame 扣除坐标轴偏移；在轴、图例及绘图区外不选择数据。浮层和竖向参考线不参与图表数据域、滚动文档布局或鼠标命中，浮层靠右／底部时翻转并夹在图表边界，图表维持固定 166 pt 高度。空白桶显示“未观测，用量未知”；有有效样本但字节为零时显示零。浮层保留部分观测说明，VoiceOver 仍可直接读取图表标记的上传／下载／合计。

关键 API 已核对 Apple 官方 `ChartProxy.plotFrame` 文档与本机 SDK 的可用性声明，最低 macOS 14；未新增依赖、采样行为或数据库结构。新测试覆盖绘图区偏移、坐标轴／图例排除、边角定位、提示内容尺寸与固定图表高度。完整回归 313 项通过；两架构构建和签名结果见 `.artifacts/chart-hover-*.log`。本轮未生成实验下载、上传或测速流量。

2026-11-06 本机安装验收：已完整替换 `/Applications/Flow Quota.app` 为 0.1.0（build 4）。首次后台服务注册出现 launchd `EX_CONFIG 78 / Launch Constraint Violation`，定向刷新 Flow Quota 的 LaunchServices 注册后，使用既有 `--repair-agent-paused` 入口恢复；未放宽签名与双向 XPC 身份校验。最终暂停自检为 `serviceStatus=1`、`pausedCheck=true`、`monitoring=paused`；安装临时启动环境恢复为原先未设置状态。schema v6、九张表的全部行内容摘要及计数在安装前后相同，完整性 ok、外键违例 0；未另建数据库副本。证据位于 `.artifacts/chart-hover-install/`（后续用户要求的产物清理可能删除这些临时证据）。

已通过原生窗口截图观察到普通网络分时图内的浮层，显示 0:00–0:05、上传／下载／合计及部分观测说明，未插入图表下方详情。未单独验收纯鼠标移出与每个边角的真实事件路径，相关坐标边界及浮层尺寸由自动测试覆盖；Intel 机器运行未验收。未为验证启动采集或产生实验网络流量。

## 按应用分时堆叠与双饼图（2026-11-06）

图表页统一时间／类别／应用选择：每个时段左上传、右下载，按应用身份堆叠；
左右两个环形图分别展示同一时段上传、下载的应用占比。服务按时段总归因选
前五应用，尾部完整计入“其他应用”；单应用选择可查任一身份。跨图颜色一致，
同名应用不合并。删除常驻饼图数值清单、独立今日口径长说明和重复横向排行；
计量范围与可能重叠的限制保留在信息图标、浮层及无障碍值。接口总量仍来自
独立物理接口，图表不把应用归因声称为接口总量分解，Clash 明细保留独立入口。

原来的应用日合计无法还原时间段，故先完成 database-design.md 的 schema v7
契约，再新增 `application_usage_minutes`。原采样事务同时更新日汇总与分钟
汇总，只记录 accumulator 确认的 measured source（包括零量），不为基线、
未知出生进程、回退或间断伪造观测；保留已确认的新进程首段增量。新的有界
XPC 查询在图表显示时按需执行，最多 300 个桶／来源组合，不把全天所有应用
分钟塞进常规 snapshot。查询、窗口选择、聚合、堆叠命中、饼图分母均以同一
对象为准；切换范围／类别取消旧请求，同查询轮询保留图形，错误明确可见。
分钟数据加入独立当前日维护，旧累计不回填。

悬停：双柱按 plot-relative x/y 命中色块，显示时段、应用及对应方向用量；
空白区域显示该方向已观测归因合计或未知。饼图按官方 `angle(at:)` 与
`value(atAngle:)` 转换，排除圆环内孔和外部；扇区浮层显示名称、字节、百分比。
浮层不参与命中／数据域／文档布局，边缘翻转并夹紧。移开或切换数据时隐藏。

验证：Swift tools 6.0 / 最低 macOS 14，实际 Swift 6.4.2、macOS SDK 27.2。
完整测试日志 `.artifacts/application-chart-final-tests.log`：327 项 Swift Testing
（Store 83、Platform 90、Core 9、App 104、Agent 41）通过，另有现有 XCTest。
覆盖 schema 6→7 事务／失败重试与无回填，零量／基线区分，网络类别与筛选，
前五＋尾部完整性，整数溢出回滚，旧日期／非对齐请求拒绝，严格当天清理及
WAL，真实 runtime→store→query 数据通路，堆叠与饼图同口径、悬停身份和扇区
边界、提示尺寸与并排布局。原生模拟渲染图仅含明确标注的模拟数据，文件
`/tmp/flow-quota-application-chart-fixture.png`，不装入生产包或正式数据库。

查询代表性测量：128 应用 × 60 分钟（7,680 行）临时库，约 4.3 ms，72 个聚合
返回行、编码回复 9,074 bytes。EXPLAIN 使用日／类别／分钟主键范围索引，无
全表扫描；这是本机夹具查询测量，不扩展为生产 CPU、采样精度或吞吐验收。
两架构编译、完整包与 Agent 签名检查见 `.artifacts/application-chart-*.log`；
Intel 实机未验证。未生成下载、上传、测速或热点实验流量。


## 实际字节双柱堆叠与多应用 tooltip（2026-11-06 用户澄清）

参考图片仅表示堆叠结构。每个时段左柱上传、右柱下载，Y 轴保持实际流量，
不归一化为百分比，也不在柱内标百分比。默认按所选范围上传＋下载总量选择
前十个应用，其他来源完整合并为“其他应用”；同名身份仍保持独立。服务查询
上限同步改为 50 时段 × 11 来源（550 行），由 Core 常量统一约束；无新增表、
迁移或采样变更。最多十种应用颜色加其他灰色，柱图、浮层和双饼图共享。

悬停任一时段上传／下载半区，浮层列出该时段所有已观测展示来源的对应方向
实际流量，按该方向用量排序、其他放最后；突出当前色块，同时显示该方向
时段合计。零量来源保留，未观测来源不伪装为零；空白时段显示未知。单应用
筛选可查看被归入其他的任意来源。浮层不加入页面布局，保留 190 点图表高度。以窗口可见滚动区定位，
最多十一行可向图表上方展开，避免短窗口裁切；悬停层置顶，不引发页面跳动。饼图保留左右布局，tooltip 仅
显示来源名与用量，不显示百分比数字，无下方常驻列表及横向排行。

验证：`.artifacts/stacked-tooltip-tests.log` 全部通过，330 项 Swift Testing
（Store 83、Platform 90、Core 9、App 107、Agent 41），另有 37 项 XCTest。
涵盖前十＋其他的完整总量、尾部应用筛选、双柱实际字节高度、方向明细、
单时段来源隔离、已观测零／未知，以及十一行浮层的原生尺寸与滚动区顶部／底部定位。
128 应用 × 60 分钟临时库读取约 5.1 ms，132 行返回、16,694 bytes，范围索引
命中；这仅是本机夹具测量。无实验下载、上传或测速流量。原生模拟渲染保留
明确“模拟数据”标识。Swift tools 6.0、最低 macOS 14，实际 SDK 27.2；沿用
Apple Charts RectangleMark 的 x/y 起止值与 ChartProxy plot-relative 悬停机制，
没有新增不确定平台 API 或依赖。两架构构建和签名见 stacked-tooltip-*.log。


最终安装：`/Applications/Flow Quota.app` 为 0.1.0（build 9），深度严格签名验证
通过。暂停替换期间 schema 7 的十张表全部行摘要／计数保持一致，完整性 ok、
外键违例 0；未创建数据库备份。临时旧 App 已删除，启动暂停环境恢复为未设置。
原有采集开关恢复 ON，最终只读自检 `serviceStatus=1`、`monitoring=collecting`，
两类网络图表 XPC 查询及展示模型验证通过；证据见
`.artifacts/stacked-tooltip-release-install/`。

原生界面确认 build 9、实际字节 Y 轴、十应用＋其他来源、双柱及左右饼图的
无障碍数据。早期候选原生截图确认了多应用悬停清单，也发现短窗口裁切；
最终版以可见滚动区定位和原生内容尺寸／边界测试修正。工具输入未稳定触发
最终窗口的连续鼠标悬停，不能宣称已完成最终版所有真实移入／移出与边角的
人工验收。相关内容、归因口径、方向、零量／未知及坐标边界已有自动覆盖。
Intel 实机运行仍未验收。安装一度出现 launchd EX_CONFIG 78、空 cdhash 约束和
XPC 超时，通过定向更新本应用的 LaunchServices 注册并运行既有暂停修复入口
恢复；安装脚本的有界重试同步刷新该注册，未放宽签名或 XPC 身份校验。

## 全局 UI 组件视觉统一（2026-11-06）

本轮以原生 macOS 设置面板为基础统一视觉语言：公共主题使用 AppKit 语义色，
卡片采用连续圆角、细分隔线、轻阴影和材质填充；页面标题、次要说明、导航选中
态和主操作按钮的层级统一。`SettingsSection`、`settingsAction`、分段类别选择、
DisclosureGroup、输入框、开关和步进器均通过共享组件或修饰器处理，避免页面各自
使用系统默认样式造成边框、圆角、间距和强调色不一致。

预警阈值、应用每日提醒和用量刷新间隔改用统一的输入控制组：标签左对齐，开关
固定靠右，数值输入使用同一圆角输入框，步进器显示当前值并提供加／减按钮。
保存、查看图表、偏好设置和安装引导按钮使用统一的普通／主操作样式；侧边栏选中
项增加蓝色指示条和柔和底色。所有状态、数据和交互逻辑保持原有实现。

验证：build 10 已通过两架构构建、深度严格签名、333 项 Swift Testing（Store 83、
Platform 90、Core 9、App 107、Agent 41）以及现有 XCTest。原生窗口已检查应用列表
和预警设置页面，输入框、短时窗口／提醒间隔控制、保存按钮、卡片和侧边栏均按新样式
渲染。替换前后 schema 7 的 10 张表行摘要一致，服务最终自检为 `serviceStatus=1`、
`monitoring=collecting`；未生成实验网络流量。

## 应用外观（2026-11-06）

通用设置中的“外观”提供“跟随系统／浅色／深色”原生分段选择，默认跟随系统。`AppAppearancePreference` 定义唯一的 UserDefaults 键 `appAppearance`；未知旧值回退到系统，选择自动保存，不触发服务调用。主应用启动时读取并设置 NSApplication.appearance，以覆盖原生窗口；菜单栏面板与独立偏好窗口分别通过同一 appAppearance 修饰器观察本机偏好并设置 preferredColorScheme，避免只更新当前窗口。跟随系统时 AppKit appearance 与 SwiftUI preferredColorScheme 均设为 nil，撤销固定外观。系统语义颜色保持动态适配。

官方依据：Apple NSAppearanceCustomization 的继承语义、NSApplication.appearance 及 SwiftUI preferredColorScheme（https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)）。实现核对本机 Xcode SDK AppKit NSAppearance.h 的 nullable appearance 声明、SwiftUI 接口及 macOS 14 下限；不更改 macOS 系统外观设置。


## 设置页多余分隔卡片修正（2026-11-06）

SettingsSection 对每个直接子项应用卡片样式；通用设置与应用详情曾把 Divider 作为直接子项，导致只有一条横线的空卡片。移除这些独立分隔项，保留实际设置卡片及卡片内部有语义的分隔线。按用户最新要求移除图表的单应用选择器及整行筛选卡片，查询固定 appKey=nil，柱图与双饼图展示全部应用，仍按时段用量取前十并把剩余来源合并为“其他应用”。左右方向及说明入口合并到柱图标题区域；保留时间范围和网络类别选择。此前章节的单应用筛选说明为历史实现，已由本次调整替代。

## 设置页布局细节修正（2026-11-06）

预警页的“短时窗口”和“同来源提醒间隔”改为标签在上、步进器在下的左对齐布局，
步进器控件与阈值输入共用内容起点，避免控件漂移到卡片右侧；默认短时窗口继续为
3 分钟。菜单栏面板使用连续圆角背景并通过 `clipShape` 裁剪内容，四角不会露出直角
材质。偏好设置顶部网络类别选择器撑满可用宽度，刷新按钮保留在独立的右侧控制位。

build 13 已完成 arm64／x86_64 构建、深度严格签名和完整回归测试。原生窗口检查确认
步进器左对齐、类别切换与刷新按钮布局；安装前后 schema 7 数据库完整性及十张表计数
保持一致。最终安装路径为 `/Applications/Flow Quota.app`，只读服务自检为
`serviceStatus=1`、`monitoring=collecting`，未生成实验性网络流量。


## 图表与应用列表来源一致（2026-11-06）

使用共享分类规则在排名前隐藏已确认的 Mihomo 内核，普通应用名称沿用 SystemProcessClassification。Mihomo 采样器仅从已通过连续性校验的连接增量更新内存分钟汇总；使用固定站点／完整应用路径归属，保留 Clash 标签。两类网络隔离，跨日含日期回退清空；暂停只重建基线，服务重启后无历史，不从累计数回填。内存每类至多 32768 个来源分钟单元，满时继续更新已有单元并在说明入口显示缺失提示；不存原始域名、连接 ID 或 IP 到分钟汇总，不新增 SQLite 表。

服务先从 SQLite 读取时段应用聚合，再合入当天本次运行的 Clash 分时聚合，统一选前十及其他。来源保留独立命名空间；Clash 不是 nettop 额度身份，不进入日账本、预警或接口总量。柱图、tooltip、双饼图共用同一展示归因，合计可能重叠，不能声称直连量或物理接口总量。图表说明入口标明 Clash 仅含更新后本次运行的有效观测，旧时段未知，覆盖不完整。IPC 只新增可选聚合元数据，保持现有字段兼容。

## 外观恢复与通用设置对齐修正（2026-11-06）

修正深色外观切回“跟随系统”后仅窗口标题栏恢复、SwiftUI 主体仍停留深色的问题。
外观选择现在直接监听保存的原始值，并由 AppKit 统一控制应用及已存在窗口的外观；切回
系统时清除窗口局部 appearance 覆盖，不再在根视图保留可能钉住旧颜色方案的
`preferredColorScheme`。

通用设置中的用量刷新间隔使用统一的行布局：标签左侧、步进器右侧；开机启动改为说明
左侧、开关右侧。已排查项目内其他开关行，菜单栏用量、网络手动热点、采集开关、每日
提醒和预警阈值均保持同一对齐规则；预警页专用步进器继续使用左对齐的上下布局。

build 15 已完成完整测试、arm64／x86_64 构建和深度严格签名。原生窗口验证覆盖浅色、
深色、深色切回跟随系统，以及刷新间隔和开机启动布局。最终服务自检为
`serviceStatus=1`、`monitoring=collecting`，schema 7 数据库完整性正常，未生成实验性
网络流量。

## 设置控件与按钮视觉统一（2026-11-06）

根据本轮界面反馈，新增共享的 `FlowQuotaSegmentedControl`、`FlowQuotaToggleStyle`、
`FlowQuotaIconButtonStyle` 和 `FlowQuotaTextButtonStyle`。外观、网络类别和图表时间范围
不再直接使用系统 segmented picker；采集、手动热点、菜单栏用量、每日提醒、预警阈值和
开机启动统一使用项目封装的原生 Switch；刷新、设置、排序、历史记录和页面操作按钮统一为圆角、细边框、
按压反馈和语义色。应用列表等整行点击入口继续保留无背景行交互，避免破坏列表的可点击区域。

用量刷新间隔步进器拆成固定的左右区域：数值在左侧区域居中，加减按钮固定在右侧，
所有短时窗口和提醒间隔步进器共用该结构。通用设置移除“用量刷新间隔”的可见解释，
开机启动移除“已开启／未开启”副文案；仍保留需要用户处理的系统批准入口和帮助页中的完整说明。
自定义控件使用 AppKit 语义色，跟随系统、浅色和深色外观均可继承，不新增业务状态或持久化字段。

验证：完整 `scripts/test-macos.sh` 通过（含菜单栏面板固定高度回归），并继续执行双架构构建、
深度签名和安装后服务／数据库自检。未生成实验性上传、下载、测速或热点流量。


## 饼图取消扇区间距（2026-11-06）

上传和下载共用 UsagePieChart，SectorMark 的 angularInset 从 1 改为 0，避免固定间距吞掉极小扇区后形成误导性的白色空白。各来源仍以实际整数 bytes 作为角度权重，不设置最小占比，也不删减小来源；合计、颜色映射、环形内径及悬停选择逻辑均保持原行为。依据 Apple Swift Charts SectorMark angularInset 参数的扇区间距语义及本机 SDK 编译，最低 macOS 14，无新依赖。此为低风险展示参数修改，不新增专用单元测试。


## 预警页布局与控件收尾（2026-11-06）

build 19 将预警设置重排为“用量阈值”和“短时规则”两组，去掉重复的“流量预警”展开层。
阈值每行统一为名称、紧凑的数值与 MB 单位、右侧开关；关闭阈值时只禁用输入，不移除该行，
保留未保存数值与布局高度。短时窗口和同来源提醒间隔使用标签左、步进器右的行布局。
记录页“全部记录／刷新记录”和“收起记录”改用标准 settingsAction，统一放到标题右侧，
修正此前使用另一种紧凑文字操作样式导致的视觉不一致。

共享按钮补齐悬停边线、按压和禁用灰显；整行入口维持原有尺寸与点击范围。主题、类别、
时间范围和 MB／GB 单位共用分段选择器，选中项使用轻量强调色。开关通过统一的
FlowQuotaToggleStyle 封装原生 Toggle.switch，保留项目对原生开关的约束以及键盘、辅助
功能和绑定语义；每个开关提供具体设置名称，使用固定尺寸，避免挤压左侧标题。实现以本机
SwiftUI SDK 的 ToggleStyleConfiguration（label、isOn／$isOn）及 SwitchToggleStyle 声明
核对，保持项目最低 macOS 14、Swift tools 6.0，不新增依赖。官方入口：
https://developer.apple.com/documentation/swiftui/togglestyle 和
https://developer.apple.com/documentation/swiftui/switchtogglestyle。

用量刷新机制、预警规则、通知条件、更新安装及采样服务等静态说明集中在“使用说明”的
SettingsUsageGuide；删除设置控件下重复的开关状态和说明段落。授权失败、通知被关闭、
采样异常、服务批准及归因容量不足仍按实际状态显示，不以精简文案隐藏异常。

原生窗口复核后，build 20 将分段选择器选中文字改用随外观变化的 primary 语义色；
强调色仅用于选中背景和边线，修正深色下纯蓝文字对比度不足。


## 菜单栏面板外层边角（2026-11-06）

PanelView 移除应用添加的 18 点圆角裁切，将 material 背景和细描边改为 Rectangle，四角内容延伸至矩形边界。内部概览卡片及按钮保持原样。仍由原生 MenuBarExtra.window 承载；本次改动仅控制应用内容形状，不使用私有 API 改写系统窗口装饰。采用现有 SwiftUI background(_:in:) 与 Rectangle.strokeBorder，最低 macOS 14。官方依据：Apple SwiftUI View/background(_:in:fillStyle:)、MenuBarExtraStyle/window。

交付：0.1.0 build 21，arm64 编译、签名和安装后暂停服务 XPC 检查通过（.artifacts/service-repair.eSJ4l9）。恢复安装前启动环境，采集保留原来的暂停状态；临时旧应用已清除。git diff --check 通过，未生成测试流量。已核对本机 SwiftUI SDK 的 MenuBarExtra 与 WindowMenuBarExtraStyle 公共声明；本次不承诺去除 macOS 系统宿主的圆角。未完成菜单栏弹窗四角的运行时截图确认。


## 预警记录表格与版本展示（2026-11-06）

0.1.1 将预警记录整理为固定表头的紧凑表格，空状态显示“今天暂无预警记录”，
计量与来源细节按需展开；共享交互样式移除悬停描边，保留禁用状态与按压反馈。
应用内当前版本、公开 Release 标题与发布说明标题只显示三段版本号，内部构建号
继续用于更新比较、清单和唯一 tag，避免新包与已发布包混淆。

发布脚本沿用 GitHub 官方 CLI 的 `gh release create --title` 设置显示名称，
不改变 tag 和资产校验流程。官方依据：https://cli.github.com/manual/gh_release_create。
完整 Swift 回归 341 项 Swift Testing 与 37 项 XCTest、52 项发布离线测试通过；
发布标题及说明标题的格式断言已同步更新。证据位于 `.artifacts/release-0.1.1-*.log`。


## 图表文案简化（2026-11-06）

按用户最终确认，柱图和左右两个饼图继续共用所选时段、来源集与配色，不改为固定全天。移除饼图上方“时段应用占比”标题，上传／下载标题与原有卡片保留。柱图的大号数值下明确标注“上传＋下载合计”，范围后标注“每组 N 分钟”，方向提示改为“每组左侧上传、右侧下载”。信息图标与无障碍描述同步使用直白表述，保留应用归因可能重叠、不等于接口总量及未观测边界。此次只调整展示文字和标题布局，不改查询、聚合、持久化或采样行为。

验证：arm64 release 编译、App／Agent 严格签名及发布静态审计通过；现有双饼图原生尺寸和离屏模拟渲染 2 项测试通过，去掉标题后未留下空卡片。测试图为明确标识的模拟数据，不代表运行中应用截图；柱图标题文案经源码核对与编译验证。未改动本机实际安装或采样服务，未生成实验网络流量。证据位于 `.artifacts/chart-copy-tests.log` 与 `.artifacts/chart-copy-build.log`。


## 预警记录可读性与状态说明（2026-11-06）

原五列表格固定宽度合计超过最小窗口可用内容宽度，导致弹性的来源列被压缩至近零。现改为时间、预警内容、用量／阈值、通知状态四列；类型使用简短名称，来源置于其下，不重复顶部已选择的网络类别。表头与记录共用宽度及间距，记录整行可展开原始类型、类别、身份及连续观测详情，未提交状态仍突出显示；已提交只表示系统接受请求。空状态继续保留表头和“今天暂无预警记录”。

原表格上方文字是三类预警运行状态与计量限制的串接，不是记录摘要。正常状态收进“状态与说明”，静态说明同步放入使用说明；读取、采样、保存及容量异常仍直接显示。现有 IPC 仅有文本诊断，因此共享展示层只移除服务明确产生的正常状态句，不按有限错误关键词隐藏其他文本；新出现的未知诊断默认可见。未修改数据库、预警判定、通知提交或分页读取语义。

验证：7 项针对性测试通过（含 500／720 pt 表格原生渲染、空状态、整行空白处点击展开／收起，以及正常状态与读取、采样、保存、容量和未知异常分离）；500 pt 内容宽度的模拟截图已人工检查，四列表头与记录对齐，来源可读。arm64 release 编译、App／Agent 严格签名及发布静态审计通过。沿用现有 SwiftUI 布局、Button／popover 与共享行按钮样式，没有新增系统能力、数据库变更或依赖。未安装替换实际应用、未启停本机采样服务、未生成验收流量；原生渲染使用明确标注的模拟记录，不作为实际预警触发验收。证据：`.artifacts/alert-history-layout-tests.log`、`alert-history-layout-build.log`、`alert-history-layout-preview.png` 及 `alert-history-layout-empty.png`。

## 2026-11-06：清理已替代的图表和界面辅助代码

- 应用分钟图表已由 `ApplicationTimelinePresentation` 统一生成。删除旧 `UsageChartData`，移除 `UsageTimelineData` 中仅旧接口图表使用的聚合／时段查找函数及两份过时测试；保留当前图表仍使用的时间槽和汇总类型。饼图仍使用的 `UsageChartValue` 移到 `UsagePieData.swift`，不改变数据和占比。
- 移除旧 `networkTitle`，网络展示测试改为核对实际界面使用的 `networkName`；删除未使用的 SwiftUI 外观映射、通知声音状态副本、通知设置文案函数、主题颜色／文字修饰符。AppKit 外观、通知授权及可处理异常继续由现有入口控制。
- 浮层高度上限属于测试验收条件，移到测试断言；同文件读取视图尺寸的测试补齐既有 `@MainActor` 约束。
- 保留当前应用图表的分组、空白与零量、溢出、来源／Clash 语义、双饼图、悬停及渲染测试。全量回归与构建结果见 `implementation-status.md` 的本次清理记录。
