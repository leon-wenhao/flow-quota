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
