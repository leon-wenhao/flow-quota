# 提醒版实施与验证记录

> 当前源码流量口径（2026-11-06）：以 [计算口径](traffic-accounting.md) 与 [完整拆分方案](clash-usage-breakdown.md) 为准。主图显示独立接口总量；Clash 已识别来源及其他未识别完整保留内核父项，日常列表、菜单栏、图表及新预警不重复加入父项。schema v9 保存当天来源分钟，原始计数与核对收进用量详情。下文早期阶段的独立辅助分组、仅内存来源和归因核对常驻页面都是演进记录，已被替代。

更新：2026-11-05，Asia/Shanghai。当前为 macOS 自用的流量采样统计与阈值通知，暂不自动阻断。本轮在独立接口总量之上加入后台大流量预警，严格遵守用户“不用热点流量做实验性验证”的限制。未来阻断仍需单独实现与验收。

## Clash 来源合入应用列表（2026-11-05）

已把 API 细分合入普通应用列表：依据固定站点域名显示 `YouTube（Clash）`、`虎牙直播（Clash）`，未知站点回退完整路径确定的应用，无法确认来源时明确显示未知。每行区分“本次代理观测”与普通应用“每日归因”，可点开查看上下行、来源应用与计量范围；已确认 Mihomo 内核隐藏于普通列表，诊断只放用量详情。DIRECT 标签也表示由 Clash 处理，不声称走代理节点。

同时修复上一版 `startMihomoSampling` 未接入主启停流程的问题。首帧／故障恢复／切网／跨日和超过八秒间隔重新基线；按类别保留本次服务运行的来源累计，关闭连接或暂停不清空，重启不回填。每类最多 128 项且容量限制可见，不保存原始域名、IP、连接流水，不写 nettop 日账本，不增加接口总量。官方字段已按 v1.19.33 固定版本核对。实现细节见 `mihomo-api.md`。

原生 SwiftUI 模拟预览保存于 `/tmp/flow-quota-clash-list-preview.png`，明确标记模拟数据。最终完整回归 **310 项通过**，无编译警告；日志 `.artifacts/mihomo-attribution-final-tests.log`。arm64 release 与严格 ad-hoc 签名检查通过，日志 `.artifacts/mihomo-attribution-build-arm64.log`。下方旧卡片和旧 schema 记录属于历史版本。

本机最终安装为 0.1.0 build 3，arm64 release 与严格签名检查通过。相同 build 2 的再次替换曾出现 launchd 无法解析 BundleProgram／EX_CONFIG；保留旧包与暂停启动环境，递增构建号后使用官方 SMAppService 重注册，正式 XPC 自检恢复成功并确认 paused。现有 31 项应用记录、预警规则版本 17 和原 8 张业务表内容摘要全部保留；当前工作区已有图表功能在安装时执行 v5→v6 迁移，仅新增 interface_usage_minutes，Clash 归因未新增表。没有 nettop 进程，未产生下载、上传、测速或热点实验流量。最终证据为 `.artifacts/mihomo-attribution-install/final-verification.json`，安装日志中保留旧包备份路径。真实 YouTube／虎牙业务字节归因尚未做联网实验验收。

## Mihomo controller API 观测（2026-11-05）

已接入 Clash Verge 当前使用的用户 Unix Socket：`/var/run/clash-verge-service/users/<uid>/verge-mihomo.sock`。Flow Quota 通过公共 Unix domain socket API 只读请求 `/connections`，解析上传／下载总量、活动连接及 `processPath`／`process` 元数据；不启动 curl、不读 controller secret、不修改配置。API 观测以本次连续运行作为范围，首帧建立基线，服务重启或计数回退重建基线。

新增代理卡片显示“本次代理观测”、活动连接数及可关联的原始进程摘要。它与物理接口总量、nettop 应用账本独立展示，可能重叠，不写 `daily_usage`，不新增数据库表，也不把代理总量加到接口总量。连接在两次 API 读取之间关闭时，来源摘要不强行归因；无法关联显示来源应用未确认。API 故障显示 stale／unavailable，不继续累计未知区间。

- **252 项完整回归通过**：Core 68、Store 9、Platform 65、App 77、Agent 33。新增 Mihomo JSON 边界、首帧／连续增量／重启基线、分块 HTTP 响应、请求路径和异常连接测试；日志 `.artifacts/mihomo-implementation-tests.log`。
- 本机实际编译的客户端通过当前 Mihomo Unix Socket 读取验证：55 条活动连接、7 条带进程路径的记录；验证只输出字段数量，`physical_interface_counters_read=false`、`mihomo_connection_bytes_read=true`、`ledger_written=false`，证据 `.artifacts/mihomo-api-check.json`。
- arm64／x86_64 构建和严格签名检查通过，日志 `.artifacts/mihomo-build-arm64.log`、`.artifacts/mihomo-build-x64.log`。完整安装后真实 XPC 自检通过，服务保持 paused；数据库 schema v4、31 条应用／当日用量和所有表摘要保留，证据 `.artifacts/mihomo-install/final-verification.json`。
- 安装过程中 launchd 再次出现开发签名缓存导致的 `EX_CONFIG 78`，通过只针对 Flow Quota 的 LaunchServices 刷新和应用内 SMAppService 重注册恢复；没有关闭代码签名校验或修改系统安全设置。
- 没有生成下载、上传、测速或热点实验流量；API 的连接内容没有写入生产库。API 只能尽力关联原始进程，不能保证所有 VPN/TUN/IPv6 场景或恢复已关闭连接的来源。实现边界见 `mihomo-api.md`。

## 用户选定 C「流量刻度」图标（2026-11-05）

第二轮三方案中用户明确选择 C。已将深青底板、薄荷绿圆角用量柱和分离阈值圆点接入 `BrandIdentity.swift`，应用 ICNS、窗口标题标记和菜单栏复用相同矢量源。SVG 导出与 SwiftUI 同用几何和配色；当时正式 1024 PNG 与选定的 C 提案 SHA-256 完全一致。2026-11-06 清理了候选稿及其独立生成器，正式几何和资源继续保留。

arm64／x86_64 构建及严格签名检查通过，日志 `.artifacts/brand-c-build-arm64.log`、`.artifacts/brand-c-build-x64.log`。此轮为纯图标变更，使用编译、生成资源比对、实际系统图标和菜单栏浅／深色模板渲染核验；没有机械新增测试或重复执行无关功能测试。沙箱内 iconutil 报 Invalid Iconset、NSWorkspace 图标读取为空白，沙箱外调用相同官方工具和读取接口后均正常，未更换图标工具或绕过签名。

已更新 `/Applications/Flow Quota.app` 并打开预览窗口。更新前发现当前采样器在运行，先通过旧应用的正式停止接口停止并等待 nettop 退出，再备份、完整替换新包和官方重注册；安装后服务自检为 paused，无 nettop，临时启动环境恢复。schema v4、27 条应用／当日用量、接口日汇总及全部表摘要与停止后备份一致，预警配置 version 17 保留。未生成网络实验流量，未更改通知授权。备份与最终证据：`.artifacts/brand-c-install/final-verification.json`；实际系统读取的新图标及模板预览也在该目录。下文原 Q 标志记录保留为历史。

## Clash／VPN 代理身份修复（2026-11-05）

本机系统代理开启，Mihomo 内核由 root 运行，Clash Verge 界面与 Flow Quota 为 UID 501。诊断时采集已暂停；另确认旧身份解析的独立缺陷：读取 root Mihomo 的 `PROC_PIDTBSDINFO` 返回 EPERM，解析器提前丢弃进程，而完整可执行路径及公开 sysctl 的出生时间均可读。

已加入仅针对 EPERM／EACCES 的 `KERN_PROC_PID` 备用读取，严格验证返回大小／PID／出生时间，继续在路径读取前后校验进程 incarnation；两个公开 API 的 token 一致。精确核对的 Mihomo 路径显示为“Clash Verge 代理内核（Mihomo）”，保留独立 exec 账本，不合并到界面；原始来源应用未知。物理接口总量仍独立，不改 TUN 接口选择，不相加代理与应用字节。

- **225 项完整回归通过**：Core 42、Store 60、Platform 58、App 48、Agent 17。新增权限错误／无效响应／PID 重用／权限变化后连续增量测试，以及合成代理计数→独立账本→应用短时预警集成测试。日志 `.artifacts/vpn-tests.log`，无编译警告。
- 本机真实 UID 501 调用本轮编译的生产 resolver，已成功识别 root Mihomo。仅传入测试零计数检查身份，未读流量、未写账本；证据 `.artifacts/vpn-diagnosis/production-resolver.json`。旧接口 EPERM 与 sysctl 成功的对照也保存于该目录。
- arm64／x86_64 构建、应用及 Agent 严格签名检查通过；日志 `.artifacts/vpn-build-arm64.log`、`.artifacts/vpn-build-x64.log`。三个相关生产文件分别 72／81／67 行。
- 已更新并重新打开 `/Applications/Flow Quota.app`。首次原地复制后 launchd 空 cdhash／EX_CONFIG78，三次官方重注册仍超时；完整新包替换、定向刷新 LaunchServices 后官方 SMAppService 与真实双向 XPC 自检成功，未放宽签名要求。备份旧应用、数据库及诊断记录位于 `.artifacts/vpn-install/`。
- 最终核对 schema v4、全部表逐字段摘要一致、19 条既有应用／当日用量保留、integrity／foreign_key 检查通过、原配置不变。服务保持 paused，无 nettop，临时启动标记已清除；证据 `.artifacts/vpn-install/final-verification.json`。
- **没有做热点实验，没有启动 nettop，没有下载／上传／测速或发送测试通知。** 真实代理字节覆盖、所有 TUN／IPv6 配置、运营商误差及 macOS 14／Intel 实机仍未验收；不追补此前漏掉的字节。完整边界见 `vpn-attribution.md`。

## Logo 与应用图标（2026-11-05）

已设计并使用原创矢量标志：开放 Q 形额度圆环、上升流线、琥珀色阈值标记和深蓝色底板。`BrandIdentity.swift` 定义共用几何，应用包 ICNS／窗口标题／菜单栏模板图像复用同一图形。PNG／SVG／ICNS 和重新生成说明保存在 `assets/brand/`；生成工具使用本地 SwiftUI ImageRenderer 及官方 iconutil，不引入在线生成服务或第三方依赖。

213 项回归通过，arm64／x86_64 构建及严格签名通过，Info.plist 与 Resources 图标对应。已更新 `/Applications/Flow Quota.app`，重新注册后的真实 XPC 自检成功；系统 NSWorkspace 读取的 512 像素应用图标、真实窗口标题截图及菜单栏模板浅／深色渲染均已检查。日志 `.artifacts/brand-tests.log`、`.artifacts/brand-build-arm64.log`、`.artifacts/brand-build-x64.log`，最终证据 `.artifacts/brand-install/final-verification.json`。

数据库仍为 v4，19 条应用／用量、旧表数据及预警配置摘要与更新前一致。当前应用打开，服务暂停，无 nettop；临时启动环境已清除。没有变更通知授权、触发壁纸下载或生成测试网络流量。菜单栏仅调整标志与状态亮度，已有辅助功能状态说明保留。

## 最新交付：后台大流量预警（2026-11-05）

- 新增接口每日总量、接口短时、每个应用／系统服务短时三类独立预警；默认 1 GB／200 MB／200 MB，窗口最多 5 分钟，同来源短时冷却 10 分钟，各项可单独关闭。原应用每日阈值提醒继续保留。
- 事件保留实际连续观测时长，可在窗口填满前触发。接口事件不依赖应用归因，应用采集失败仍可投递；暂停、过期、跨日或版本变化不得发送旧提案。通知状态明确区分事件落库与系统接受请求。
- schema v4 新增全局配置、当天事件两类实体，事务迁移保留旧数据；事件兼作待发队列，最多 256 条／天。窗口有 128 个应用来源、450 桶边界，失败可见，应用窗口故障不阻断接口检查。
- 原生设置、当天事件预览／分页、系统来源友好名称已接通。壁纸分类只按核对的精确路径，nsurlsessiond 标为共享服务，不能认定其原始请求方或用途。
- **213 项完整回归通过**：Core 41（36 XCTest＋5 Swift Testing）、Store 60、Platform 48、App 48、Agent 16。模拟 12GB 未归因接口增量、独立应用、窗口边界、容量、时钟回拨、迁移回滚、并发、重启去重、配置关闭、ACK 重试和状态观察通过。日志 `.artifacts/traffic-alert-tests.log`，无编译警告。
- arm64／x86_64 应用包构建与 `codesign --verify --deep --strict` 通过；日志 `.artifacts/traffic-alert-build-arm64.log`、`.artifacts/traffic-alert-build-x64.log`。全部生产 Swift 文件少于 300 行。
- 已更新 `/Applications/Flow Quota.app`。生产库 v3→v4、integrity_check／foreign_key_check、新配置与空事件表通过；19 条既有应用／用量及其余旧表逐字段摘要一致。备份旧应用和 SQLite 库位于 `.artifacts/traffic-alert-install/`，迁移前后记录为 before.json／after.json。
- 安装时前两次系统注册出现已知开发签名缓存问题（launchd EX_CONFIG78／空代码哈希，XPC 超时）；第三次通过官方 SMAppService 注销／重注册成功，严格签名与双向 XPC 仍开启。成功记录 `.artifacts/traffic-alert-install/service-check-3.json`：paused、policyVersion=1、historyPageCount=0、pendingTrafficAlertCount=0；不代表所有后续重建均无需修复。
- 已通过真实原生界面检查：暂停状态、当前日空事件与“加载当天全部记录”、设置展开、1000／200／200 MB、5 分钟窗口／10 分钟冷却和保存按钮的滚动布局。没有保存实验配置或请求通知授权。临时启动环境已清除，应用打开且服务保持暂停，无 nettop。最终签名、二进制摘要、真实 XPC 和数据保留记录见 `.artifacts/traffic-alert-install/final-verification.json`。
- **未做热点实验，未触发壁纸下载，未生成下载／上传／测速，也未发送测试通知。** 真实采集期间的告警、通知授权／横幅展示、macOS 14／Intel 运行及长期资源表现尚未验收。11 月 4 日旧用量无法追溯重建。功能及维护入口见 `traffic-alerts.md`；下文 v3 和更早记录保留为历史。

## 已实现

- 原生 SwiftUI 菜单栏界面、提醒阈值编辑、高成本网络自动计量、手动热点标记、后台刷新和通知授权入口。
- 固定系统 nettop 命令，2 秒采样，单子进程、伪终端及时输出、完整 CSV 帧、输入/队列上限、失败和超时可见。
- libproc 公共 SDK 查询进程出生时间与路径，校验 PID 重用，归并最外层 .app 辅助进程；不能归属的进程不冒充已识别。
- 首次基线、连续增量、切网/跨日/间断/计数回退重建。新进程只有出生时刻能证明位于连续已观测区间内，才计入首批计数。
- 独立接口总量通过公开 SDK 的 `sysctl NET_RT_IFLIST2` / `if_data64` 读取单个明确物理接口的 64 位收发字节差，独立每 2 秒采样；不依赖 nettop 是否成功。首帧、切网、跨日、故障和间断均重建基线。
- SQLite schema v3 新增独立实体 `daily_interface_usage`，版本化事务迁移保留应用数据，不用应用合计回填。服务持有写连接，UI 不直接操作数据库；接口任务可独立清理过期日汇总。
- 顶部及菜单栏显示“今日计量接口总量”，应用列表显示“应用用量分析（可能重叠）”。已保存总量在暂停/接口失败时保留并显示原因；无有效接口记录显示未知，不伪装成零。应用阈值仍按应用归因计数。
- 提醒配置保存 ACK 表示持久化完成。接近阈值和达到阈值事件由实际持久化计数生成，按应用、日期、规则版本、种类去重。
- 主应用保持运行时，每 5 秒检查事件，不依赖菜单面板是否打开。UserNotifications 接受调度后才向 Agent 确认；拒绝授权、调度失败和确认失败不伪装成送达。
- 退出等待停止采集 ACK；若服务不可达，可明确选择“仅退出界面”，此时不保证后台采集停止，且主应用不再投递通知。
- 应用及后台服务身份校验、数据目录权限和原有预算规则回归保留。

## 当前验证结果

本机 Xcode 27.2 / Swift 6.4.2 / macOS SDK 27.2，Apple silicon macOS 27.2，最低编译目标 macOS 14。

- 当前完整回归 **164 项通过**：Core 29、Store 39、Platform 48、App 37、Agent 11。最新日志：`.artifacts/paused-install-tests.log`（独立接口首轮日志保留为 `.artifacts/interface-meter-tests.log`）。
- 验证使用注入的系统调用响应、模拟计数器、网络观察替身、临时 SQLite 库和通知替身。覆盖 64 位大计数、回退/溢出、跨日/切网/重启/间断、接口歧义、读取期间切网、停止取消、v1/v2 迁移、事务回滚、查询计划以及接口总量与应用归因分离。
- arm64 与 x86_64 构建成功，均通过 `codesign --verify --deep --strict`；仅为本地 ad-hoc 签名。最新日志：`.artifacts/paused-install-build-arm64.log`、`.artifacts/paused-install-build-x64.log`。Intel 运行未验证。
- 手写生产 Swift 共 57 个文件，最长 234 行；无第三方包依赖。
- **本轮没有下载、上传、测速、运营商对照、真实接口采样或热点流量实验。** 编译/模拟测试不代表真实接口支持情况、VPN 行为、CPU 指标或账单误差已验收。
- 15:13–15:19（Asia/Shanghai）已更新并打开 `/Applications/Flow Quota.app`，正式安装库从 v2 迁移至 v3，真实 XPC 的两次快照为 `.paused`，应用和接口采样时间均为空。应用与 Agent 各一份、无 nettop；未用新版本读取热点计数。完整证据：`.artifacts/paused-install/final-verification.json`。

## 本轮本机安装与暂停验收（2026-11-05）

- 安装前正常停止旧 UI/Agent，确认无 nettop；旧应用和数据库备份保存在权限受限的 `.artifacts/paused-install/`。不删除或重建生产数据库。
- 新增仅开发包生效的 `FLOW_QUOTA_VERIFY_PAUSED=1` 冷启动开关、`--repair-agent-paused` / `--verify-agent-paused`。暂停修复保留 SMAppService 注册和 XPC 双向代码身份校验，不发送开始采集；冷启动自检要求采样时间为空、无待发通知。
- launchd 首次重注册仍报告 `EX_CONFIG 78 / needs LWCR update`；经 LaunchServices 刷新和第二次官方注销/注册恢复。未关闭签名校验、修改 SIP 或绕过后台服务批准。
- 首次失败回调暴露 Swift 主 actor 继承警告；将 ObjC XPC 错误回调显式标为 `@Sendable`，重跑失败路径后不再产生该警告，随后正常连接。最终自检 stderr 为空。
- 真实安装库 schema 2 → 3，`quick_check=ok`、外键违规 0。升级前后 19 条应用、19 条当日用量、规则和通知记录的校验摘要一致；原库没有自定义规则。接口表为 0 行，未把旧应用合计伪造成接口用量。
- 已检查真实窗口截图及辅助功能树：总量缺失显示未知、暂停原因明确、设置、应用列表滚动和阈值编辑页正常打开；未保存测试规则或改变用量。基础 Tab 操作未形成完整键盘/VoiceOver 验收。
- 60.599 秒暂停状态观察：Agent 平均 CPU 0.050%、峰值 RSS 11,568 KiB；UI 在界面操作期间平均 CPU 2.046%、峰值 RSS 139,840 KiB。全程未出现 nettop。这里只证明暂停状态的短时表现，不代表真实采集或长期稳定性。
- 当前系统通知为“尚未请求授权”，没有自动允许通知或发送假阈值事件；授权与实际横幅仍待用户操作。当前连接报告高成本，因此真实接口计量、VPN/切网与睡眠等验收继续留待非热点环境。
- 结束时临时 launchd 环境变量已恢复，应用保持打开，服务暂停；正常使用需用户显式点击“启用服务并恢复采集”。

## 之前提醒版的真实验证（历史，不是本轮接口总量证据）

以下记录发生在用户提出本轮“不用热点流量做实验性验证”的限制之前，保留用于追溯。它们验证的是旧 nettop 应用采样，不能证明新增物理接口总量可用或接近运营商口径。

- 在沙箱外以普通用户运行真实 Agent：持续采样、路径归属、事务入账通过。一次 10 秒检查观察到 6 个应用/进程，其中 2 项非零，无法归属的进程数量在覆盖说明中保留。
- 受控 Apple 官方文档下载：文件 37,172 bytes，系统报告 curl 下载 41,281、上传 585 bytes；对应数据入账，并针对测试库的 100-byte 阈值生成一条达到阈值事件。结果：`.artifacts/controlled-reminder-result.json`。该记录不作为计量精度或账单准确性结论。
- 对照试验修正了首次进程突发被基线丢弃的问题；保守规则仍不补算已有进程的未知历史。
- 曾启动旧 `.app`，通过辅助功能树检查服务、设置和退出选项；未完成截图/视觉布局、VoiceOver 或完整键盘验收。

## 本机集成修复记录：LaunchAgent 启动路径（历史）

已定位并修复桌面 XPC 超时的直接原因。`SMAppService` 使用 `BundleProgram` 启动 LaunchAgent 时，launchd 传入的 `argv[0]` 是 `Contents/MacOS/FlowQuotaAgent` 这样的相对路径，而当前工作目录不是应用包根目录。Agent 原先用 `CommandLine.arguments[0]` 推导宿主 App，因而返回“请从完整 Flow Quota.app 启动本地服务”并以退出码 1 结束；主应用随后只能看到 XPC 超时。

Agent 现在使用 Foundation 的 `Bundle.main.executableURL` 获取实际绝对路径，再执行宿主 App 和代码身份校验。回归验证在无工作目录、相对 `argv[0]` 的 launchd 作业中完成：修复前为 `last exit code = 1`，修复后保持 `state = running`，Mach endpoint 显示 `active = 1`。

2026-11-05 09:35（Asia/Shanghai）已从正式安装包 `/Applications/Flow Quota.app` 执行真实 `SMAppService.unregister()` → `register()` 并通过现有 `AgentClient` 双向签名校验取得两次快照，确认采样时间推进、状态为 `collecting`、返回 10 个应用/进程。结果：`.artifacts/installed-service-check.json`。`launchctl print` 显示服务 `running`、Mach endpoint `active = 1`，`lsof` 确认实际可执行文件来自 `/Applications/Flow Quota.app/Contents/MacOS/FlowQuotaAgent`。

随后从正常应用设置页实际点击“修复开发服务”，界面显示重注册成功，并恢复“正在采集 · 阈值提醒”；09:37:45 的采样与 09:37:47 的服务快照已通过原生辅助功能树读取，应用列表正常显示。当时版本要求手动标记，因此保持零累计；此行为已由下述高成本自动计量更新替代。

新增仅开发构建可用的可重复自检入口：从完整安装包执行 `"/Applications/Flow Quota.app/Contents/MacOS/FlowQuota" --verify-agent-service`，通过正式客户端检查两次快照与采样推进；`--repair-agent-service` 先调用现有开发服务修复流程，再做同样检查。标准输出只含状态、时间和应用数量，不导出路径列表、用量或规则；任一检查失败退出码为 1。自检结束保持服务运行，供正常 UI 接管；不能把自检进程退出当作“停止采集”。

通知授权仍为尚未请求。需用户在应用中允许阈值提醒，再验证实际系统通知接受/拒绝与横幅展示。没有自动批准权限、修改登录项、SIP 或安装任何过滤扩展。

当前正式安装包的界面和后台采样服务保持运行。临时诊断探针与调试 launchd 作业已清理；正式用户数据库保留。

## 本机 CPU 修复记录（2026-11-05）

现场发现 7 个 nettop，其中 6 个 PPID=1，为此前调试/重注册未回收的残留；各进程约占 70%～124% CPU。已仅终止确认过的 6 个残留 PID，没有按进程名批量结束其他程序。

同参数对照进一步确认：launchd 下默认 stdin 为 `/dev/null`，nettop 在 CSV 模式仍监听输入，持续 EOF 导致其内部 dispatch 源忙循环。7 秒累计 CPU 增量：null 138.93%、保持打开的管道 0.43%、伪终端 0.71%，三组都有 CSV 输出。修复将 stdin 与 stdout 都连接到同一伪终端 slave，保持原来 2 秒采样参数和输出解析规则。

Agent 新增 SIGTERM/SIGINT 停机处理，启动取消和停机按顺序执行；启动失败也清理采样。停止 ACK 额外等待独立 I/O 队列回收子进程，避免 AsyncStream 消费任务先返回。信号停机最多等待 5 秒，超时明确以失败结束；SIGKILL/崩溃无法执行此清理，不承诺该场景无残留。

验证结果：

- 新增 3 个停机时序/超时/失败测试，完整 100 项回归通过；arm64、x86_64 构建及严格签名校验通过，Intel 仅编译。
- `python3 scripts/check-sampler-lifecycle.py ".artifacts/arm64/Flow Quota.app/Contents/MacOS/FlowQuotaAgent"` 使用临时数据库验证真实采样、正常退出和 SIGTERM 回收；5.06 秒采样 CPU 0.2%，结果 `.artifacts/cpu-lifecycle-check.jsonl`。该检查需在允许系统进程观测的环境运行，CPU 上限用于本机空闲回归，不是所有负载下的性能保证。
- 已更新 `/Applications/Flow Quota.app`。覆盖开发签名后首次注册遇到旧 LWCR 元数据，定向 `lsregister -f` 刷新此应用后解决；随后连续两次官方服务重注册及双向 XPC 自检通过，状态 collecting，系统中仅一个 nettop 且其父进程为当前 Agent。结果 `.artifacts/cpu-service-repair-1.json`、`.artifacts/cpu-service-repair-2.json`。
- 10:03 左右稳定运行 10.05 秒测量：UI 1.39%、Agent 0.20%、nettop 0.40%，合计约 1.99%；100% 表示占满一个 CPU 核心，按累计 CPU 时间差计算，短时结果不代表长期峰值。证据 `.artifacts/installed-cpu-after.json`。
- 原生界面显示正在采集，采样与快照时间推进。应用及采样保持运行；未修改热点标记、通知授权或正式用户数据库结构。

## 高成本网络自动计量验证（2026-11-05）

用户批准系统高成本信号自动计量。新增 `.expensive` 与手动标记 `.hotspot` 区分，两者共用原每日应用用量与提醒预算；普通/未知路径不自动计入。网络更新撤销手动标记、重新判断并重建基线，不清空已有当日用量、不回填跨网间断。UI 标注“高成本网络 · 已自动计量”，自动状态隐藏重复标记按钮。未新增数据库表、迁移或定位权限；仍只提醒，不阻断。

- 109 项完整回归通过，包含 5 个网络状态/跨网累计测试、4 个网络呈现/提醒测试；共享向量增加高成本范围下的阈值、提醒与去重案例。
- arm64 与 x86_64 构建通过严格签名校验，Intel 未运行；日志 `.artifacts/automatic-metering-build-arm64.log`、`.artifacts/automatic-metering-build-x64.log`。
- 真实临时数据库测试完全未调用手动标记：系统状态 `.expensive`、采集 `collecting`；37,172-byte 官方文档下载后，curl 入账上传 585 bytes、下载 41,282 bytes。网络计数含不同协议口径，不能按文件大小宣称计量精度。结果 `.artifacts/automatic-metering-live.json`。
- 更新本机安装包并刷新开发签名服务注册后，通过正式签名验证的 XPC 自检报告 `network=expensive`、`monitoring=collecting`，采样时间推进。结果 `.artifacts/automatic-metering-installed-service.json`；launchd running，系统仅一个 nettop，父进程为当前 Agent。
- 11:10:38 原生辅助功能树确认真实应用显示自动计量且没有手动标记入口；合计 434 KB，其中 Chrome 362 KB、微信 56 KB，其他应用按观测增量显示。最终 11:14:02 再次确认合计 1.3 MB、Chrome 1.1 MB，更新应用后已有当日用量保留并继续累计。未授权通知、未自动改变用户网络设置。最终应用与采集服务保持运行。

最终 10.06 秒资源检查只有一个 nettop（父进程为当前 Agent），平均 CPU 0.6%、Agent 0.2%；UI 含启动阶段为 3.78%。结果 `.artifacts/automatic-metering-cpu.json`，未将短时测试当作长期峰值保证。

自动依据是系统成本信号，不承诺识别全部手机热点或运营商；该信号未报告时仍需手动标记。上述本机观测不覆盖 USB/Android、VPN/TUN、多网卡切换或长期准确性，仍沿用下述产品边界。

## 本轮构建与安装产物

- Apple silicon：`.artifacts/arm64/Flow Quota.app`；已安装到 `/Applications/Flow Quota.app`，最终二进制摘要与构建产物一致。
- Intel：`.artifacts/x86_64/Flow Quota.app`，仅完成编译。
- **先前提醒版 DMG（不含独立接口总量、自动计量、CPU/生命周期修复、启动修复和自检入口，不是本轮验证包）**：`.artifacts/FlowQuota-0.1.0-dev-arm64-20261105-002226.dmg`。
- SHA-256：`5b37347e084057a5cba494553c712d0940dbe4dfade6e46684effa4b005d0245`。
- 上述 DMG 的历史构建日志：`.artifacts/reminder-build.log`、`.artifacts/reminder-build-x64.log`、`.artifacts/reminder-package.log`。本轮 .app 日志见当前验证结果。

2026-11-04 的旧 DMG 仅为基础样机，不含本轮真实采集，不应作为当前提醒版验证包。当前包不含网络过滤扩展，没有正式分发、公证或下载隔离环境验收结论。

## 仍需验证的产品边界

- 本轮正式安装、暂停 XPC、生产库迁移和窗口布局已检查；真实接口采样、通知允许/拒绝与横幅展示仍待验收。后续真实验证必须继续遵守用户的热点实验限制。
- 应用在两帧间启动并退出、已有进程新连接、源移除/重置、系统服务归属可能漏计。采样启动前及中断期间用量未知。
- Wi-Fi/USB 热点、Clash 系统代理/TUN、多网卡、共享系统进程的归属与重复；不把应用合计当作物理接口计费流量。
- 休眠/重启/时钟与时区改变、历史日期回拨、长时间资源使用、物理断电、最低系统版本与 Intel 真机。
- 不承诺系统接受通知后必定展示，也不承诺崩溃重试时恰好一次横幅。主应用退出后不投递提醒。
- 自动阻断尚未实现；未来单独恢复 `tasks/002-real-filter.md`，不得将提醒版当作保护引擎通过验收。


## 自定义用量刷新间隔（2026-11-05）

设置「通用 → 用量刷新间隔」支持 1–5 秒整数选择，默认 5 秒，通过 AppStorage/UserDefaults 自动保存。AppMonitor 每次服务读取和通知处理完成后读取最新偏好，从下一轮等待生效；不取消已经在进行的通知提交、不启动重复轮询。界面、菜单栏和通知检查共用此周期，后台接口及 nettop 采样保持约 2 秒，不改变采样基线、数据库或预警窗口。范围上限保留原通知检查节奏；1 秒显示刷新不保证每次都有新样本。无效偏好回退为 5 秒。

验证：12 项针对性测试通过，包括新建偏好默认值、独立 UserDefaults 域重新读取保存值、无效值回退、运行中由 1 秒切换到 5 秒而无需重启、轮询停止取消、隐藏面板投递、暂停／过期／授权期间状态改变、接口预警独立投递及 ACK 重试。测试仅使用 FakeAgentClient 和独立偏好域；未采样真实接口，未制造上传／下载／测速流量。arm64 与 x86_64 开发 app 构建及脚本严格签名校验通过，产物分别在 `.artifacts/arm64/Flow Quota.app` 与 `.artifacts/x86_64/Flow Quota.app`。本次未启动新包、未更换 `/Applications` 安装版，也未完成新增控件的原生交互验收；最低系统及 Intel 真机仍待验证。官方依据见 official-references.md「用量刷新偏好依据」。


## 开机启动改为 switch（2026-11-05）

设置页开机启动改为与菜单栏显示用量一致的原生小尺寸 switch；继续显示系统确认的开启／关闭状态，异步操作期间禁用，失败沿用共用错误反馈，需系统批准或应用未找到时保留设置入口。arm64 开发包重建与构建脚本签名检查通过，已用 ditto 替换 `/Applications/Flow Quota.app`。按用户此前要求未增加测试或交互验收，未启动应用、切换真实登录项或采样。重新打开应用后可见新控件。


## 全应用 Switch 统一（2026-11-05）

已检查全部 FlowQuotaApp 控件：菜单栏用量显示、开机启动、应用每日阈值和三类全局预警原本已是 Switch；本轮将主面板及设置／用量详情的流量采集入口、主面板手动热点标记统一为原生小尺寸 Switch。采集控制复用 SamplingControl，服务确认前不改成成功状态，操作期间禁用；暂停保留累计、不退出应用。未知或旧版服务状态保留显式连接动作，通知权限仍通过系统授权动作处理，加载／收起、导航、保存、刷新和退出保留原动作语义。该界面约束已同步 AGENTS.md。

IPC 快照新增可缺失 samplingEnabled，以服务采样任务状态区分“已启用采集”和“应用归因健康”；应用失败且接口独立运行仍显示采集启用，缺字段／过期／断连不伪装为关闭。不新增数据库实体或迁移。7 项针对性测试通过，覆盖确认式暂停／恢复、操作期间防重复、暂停失败、独立接口运行、未知／过期／断连、旧快照兼容和手动／自动网络语义。测试只用 FakeAgentClient、模拟任务与临时数据库，不启动真实采样或生成网络流量。为恢复测试编译，补齐 SamplingClockTests 的 FlowQuotaCore 导入；测试内容和断言不变。

arm64、x86_64 开发构建及脚本签名检查通过，已将 arm64 新包替换到 `/Applications/Flow Quota.app`。未重启应用／后台服务、未操作真实开关或执行交互验收。旧开发服务若仍驻留，需通过设置内既有「修复开发服务」刷新注册后读取新版快照；不因本次替换自动恢复采样。真实运行行为和通知横幅仍沿用既有待验收边界。


## 短时预警五项逻辑修复（2026-11-05）

已修复审查复现的休眠跨窗误报、无关应用计数回退导致的漏报、事件写入失败丢失窗口、每日异常短路接口短时检查、持续 129 来源状态误报。使用 `CLOCK_MONOTONIC_RAW` 连续单调纳秒；应用回退按规范身份隔离；最早已达阈值的事件以原 UUID/原时间/原用量有界保留并在对应采样回调后重试；每日／接口短时／各应用入库异常分别处理；来源基线也校验容量，恢复首帧显示等待连续采样。暂停／配置变更使旧异步评估失效。没有数据库 schema 变更。

新增 16 项正式回归测试（Core 3、Platform 2、Agent 11）。针对性 82 项通过；完整测试 267 项通过：XCTest 37、Store 61、Platform 60、Core 8、App 72、Agent 29，日志 `.artifacts/alert-fix-full-tests.log`。arm64／x86_64 主应用与 Agent 构建、包和独立 Agent 严格签名验证通过，记录 `.artifacts/alert-fix-build-arm64.log`、`.artifacts/alert-fix-build-x64.log`、`.artifacts/alert-fix-signatures.log`。构建产物位于 `.artifacts/arm64/Flow Quota.app` 与 `.artifacts/x86_64/Flow Quota.app`；已备份并完整替换 `/Applications/Flow Quota.app`，通过真实签名应用的 `--repair-agent-paused` 正式注册／XPC 自检后重新打开主应用；服务为 paused，无 nettop。安装前后 schema v4 与全部表内容摘要一致，27 条应用记录、预警配置 version 17 保留。旧包和 SQLite 备份在 `.artifacts/alert-fix-install/`，最终证据为 `final-verification.json`；临时 launchd 启动环境已恢复。

验证仅使用注入的连续计时／接口计数、临时 SQLite 故障触发器与模拟进程计数；本地 /bin/cat 仅提供真实进程身份以覆盖完整 ingest 路径，不采集或生成网络流量。未进行真实休眠唤醒、热点流量实验或真实通知横幅验收。内存重试最多 130 项（2 个接口类别、128 个应用来源），退出服务会丢失尚未入库的候选；入库后的持久化通知待发／ACK 语义保持原约束。详见 `traffic-alerts.md` 和 `official-references.md`。

## 用量图表与版本更新检查（2026-11-05）

已按 `docs/tasks/006-charts-and-updates.md` 完成第一阶段实现：

- `UsageChartsView` 使用 macOS 原生 Swift Charts，在用量详情中展示接口上传／下载、应用归因排行及接口每日预警进度。
- 图表只读取当前有效的 `AgentSnapshot`；服务未连接、快照过期、跨日或采样不可用时显示未知提示，不伪造零值。
- 应用归因图表明确标记为分析用途，不把应用合计画成接口总量百分比，也不从两者差值推导未知来源。
- 新增 `UpdateChecker`、版本比较和 JSON 清单校验；设置页显示当前版本、检查状态和手动检查按钮。新版本只打开 HTTPS 下载页，不自动替换应用。
- 更新清单为仓库根目录 `update-manifest.json`，当前清单版本为 `0.1.0` build `1`；正式发布时需同步更新版本、build、最低系统版本和下载地址。
- 版本检查未接入 Sparkle 自动更新；当前项目仍是 ad-hoc 开发签名，正式自动更新需等 Developer ID 签名、公证和发布清单流程单独验收。

验证结果：Swift 全量测试通过；新增图表数据测试 2 项、版本检查测试 4 项通过。主应用 debug 构建通过；release arm64 与 x86_64 应用包构建及项目脚本内的严格 ad-hoc 签名检查通过。未进行真实网络流量实验、未下载或安装外部更新包，GitHub 远程清单的线上可达性需在清单提交到远程后再验证。


## 覆盖更新后服务连接异常恢复（2026-11-05 19:43，Asia/Shanghai）

用户截图显示服务未连接且仍是旧版按钮。只读检查发现界面进程 PID 93015 自 19:18:25 运行；安装文件已更新，后台 Agent 不存在，launchd 为 spawn failed／EX_CONFIG 78。系统日志明确记录 OS_REASON_CODESIGNING / Launch Constraint Violation，程序路径可解析到安装版但启动约束不匹配；LWCR 的 cdhash 项在 launchctl 文本中不可读，不能仅凭该打印格式断言文件签名为空或损坏。安装包静态签名检查仍通过。

首次整体替换完整包、刷新 LaunchServices 并直接运行暂停修复入口，连续三次 XPC 超时。随后发现 LaunchServices 同时记录旧 DMG、构建目录和安装版；只注销这三个 Flow Quota 注册记录后重新登记安装版，并通过 open -n -W -a 的系统应用启动流程执行既有 --repair-agent-paused，成功完成 SMAppService 注销／重注册和双向签名 XPC 检查。这些恢复动作组合执行，未单独隔离各动作对旧注册／启动约束的影响，不能将某个旧副本单独判定为唯一原因。没有放宽代码身份要求、关闭系统验证或更换服务架构。

成功证据 `.artifacts/service-repair.i9Lfvv/service-launchservices.json`：serviceStatus=1、monitoring=paused、pausedCheck=true，读取 27 项既有应用来源，无待发预警；两次快照时间推进但采样时间不推进。后续 launchctl 的 Agent PID 34508 为 running，Mach endpoint active；未发现 nettop。已打开新版界面，原生 AX 状态确认「应用采集已暂停」、流量采集 Switch 为 off，底栏无服务连接异常。仅确认当前数据可读取，未做数据库逐行前后对照，不扩展为计费精度验收。

已清除本次保留的临时 launchd 暂停启动标记，现有服务仍暂停，未自动恢复采样。旧安装包保存在同目录 Previous Flow Quota.app。新增 scripts/install-macos-dev-paused.sh 固化成功的完整包替换、限定副本注册清理、系统正常启动下的官方修复与 XPC 确认流程；拒绝在 Agent／nettop 正运行时直接替换，保存旧包及环境快照，失败保留暂停启动保护并明确报告。脚本 shell 语法检查通过；最终组合脚本没有再次重跑，避免重复改动已恢复服务。本轮未产生实验上传、下载、测速或真实接口采样。

## macOS 发布准备流程（2026-11-05）

已补齐可重复的本地开发版发布准备流程：

- `macos/Configuration/version.env` 作为版本和 build 的单一输入；`scripts/set-version.sh` 同步更新 `Info.plist` 和 `update-manifest.json`。
- `scripts/build-macos.sh` 在构建时把版本注入最终 `.app`，DMG 文件名不再写死 `0.1.0`，支持 `--dmg-output` 输出到指定发布目录。
- `scripts/release-macos.sh` 会检查三个版本来源一致，构建 arm64／x86_64 DMG，生成 `SHA256SUMS`、`release-manifest.json`、更新清单副本和发布说明模板。
- 发布步骤和命令见 `docs/release-macos.md`；脚本不创建 GitHub Release、不上传文件、不执行 Developer ID 签名或公证。

使用当前 `0.1.0` build `1` 实际运行发布准备脚本，两个 DMG 均生成成功，两个 SHA-256 校验均通过，最终 `.app` 的 `CFBundleShortVersionString` 和 `CFBundleVersion` 分别为 `0.1.0` 和 `1`。系统 Python 使用绝对路径，避免本机失效的 Conda 架构阻塞发布脚本。


## 双网络类别统计与独立提醒（2026-11-05）

热点／高成本（metered）与普通网络（ordinary）均在采集开启时统计。可用高成本路径与
手动热点共用 metered，普通 Wi-Fi／有线使用 ordinary；未知网络不分配新增量。
接口每日累计、应用每日累计／规则版本、全局预警配置、应用通知去重、事件冷却均按
类别隔离。普通网络新配置三类预警关闭，无应用每日规则；已有 metered 设置保留。
两类事件共用当天 256 条上限；仍不保存采样流水、内容或跨日历史。详细设计见
network category 章节及 database-design.md schema v5。

新增 TrafficCategory / TrafficCategorySnapshot，主快照同时提供两类账本，保留旧的
metered 字段和请求兼容。旧服务缺失普通类时，UI 显示未知且禁用编辑。服务将类别
传入应用与接口提交、通知判定／ACK、策略及历史读取。切换类别重建采样基线和滚动
窗口，不搬移已提交流量；保存非活动类别配置不清空活动窗口。旧通知键缺失类别时
按 metered 解码，并保留 metered 的旧 OS 请求 ID，ordinary 使用独立请求命名空间。

面板顶部增加原生分段类别选择，总览、应用、图表、记录及提醒设置跟随查看类别，
实际连接仍单独展示。菜单栏标注查看类别。手动热点只修正实际连接分类，关闭后
普通网络仍会统计。编辑器捕获打开时类别，避免另一窗口切换查看范围后把草稿写入
错误账本。通知标题／正文标明类别，后台投递不受当前查看类别影响。

验证：完整 **284 项测试通过**（XCTest 37、Store 68、Platform 60、Core Swift Testing 9、
App 77、Agent 33）。新增 16 项针对分类隔离、旧字段保留、DDL 中途失败回滚、缺失旧
配置拒绝迁移、重启、跨日清理、全局事件容量、模拟接口切换、应用窗口／提醒独立、
旧 IPC 兼容、跨窗口编辑目标的测试。保留约束测试改用显式列名，避免列数变化使测试
只验证 SQL 语法而未验证实际约束。共享规则向量已同步；类别点查询和预警去重查询
的 EXPLAIN QUERY PLAN 使用对应索引。日志：.artifacts/network-categories-tests.log。

Apple Silicon 和 Intel 构建／严格签名验证通过，开发包版本为 0.1.0（build 2），日志
.artifacts/network-categories-build-arm64.log 和 network-categories-build-x64.log。
最低系统版本 macOS 14，Xcode 27.2 / Swift 6.4.2；未新增第三方依赖或 entitlement。
数据库迁移参考 SQLite ALTER TABLE 官方说明；本项目只替换无入向外键的子表，
整个迁移保留 foreign_keys=ON 与最终 foreign_key_check，失败事务整体回滚。

本机安装：先用旧签名应用的 --verify-agent-paused 确认暂停并备份生产 v4 数据库，
整体替换 /Applications/Flow Quota.app。首次脚本在清理未登记开发包时遇到 -10814，
已修正为仅将该已知“无登记”结果视为可继续；其他错误仍失败。随后同 build 1 注册
出现系统启动约束不匹配／EX_CONFIG 78，静态签名通过；递增至 build 2 后使用相同
SMAppService 和严格 XPC 要求注册成功，未关闭安全检查。构建号变化与重登记共同
完成恢复，不能据此断言单一缓存原因。正式发布清单仍保持已发布 build 1，本轮未发布。

最终真实 XPC 证据：.artifacts/service-repair.VoYbi3/service-1.json，确认服务 enabled、
monitoring=paused、trafficCategories=[metered, ordinary]、ordinaryRemindersEnabled=false，
31 个已有来源可读，metered 预警版本 17 保留。生产库 schema=5；8 张旧表的业务字段
投影与暂停前备份逐表摘要一致（设置表的旧固定 id=1 映射为 metered），完整性检查 ok、
无 FK 违规。ordinary 账本尚无应用／接口采样行，未把未知旧流量造为零。证据与数据库
备份：.artifacts/network-categories-install/；最初旧应用在
.artifacts/service-repair.vwuWUn/Previous Flow Quota.app。临时启动环境已清理。

当前新版已重新打开，服务保持暂停，无 nettop；用户可在采集 Switch 自行恢复。
未用热点流量进行实验，未验证真实跨网络计量误差或通知横幅展示；接口及应用归因仍
受既有多网卡／VPN／共享服务边界约束，不承诺运营商账单精度。

交付时发现其他会话正在并行新增 Mihomo API 观测代码（AgentMihomoSampling 等）；本节测试、构建及安装证据对应本轮 build 2，未替换、回退或验证其他会话尚在编辑的功能。


## 当天分时图、饼图及图表快捷入口（2026-11-05）

代码已实现：主面板「用量图表」快捷入口直接打开 UsageDashboardView。该页面
在并行的偏好窗口改造中也通过 PreferencesNavigation.charts 复用；本任务不覆盖
对方的 PanelView／OverviewView 后续改造，不并行替换或重新注册安装版。

- 今日接口上传／下载、今日应用归因分别使用环形饼图及字节／百分比图例。应用
  前五项加「其他应用」，分母包含全部有效归因；同名应用保持原身份，归因可能
  重叠的说明保留，不把应用占比当作接口份额。
- 页面首屏为接口分时图，支持最近一小时、今天、当天自定义起止。短范围按
  5 分钟、长范围按 30 分钟聚合，选择时段显示上下行、记录分钟数及有效样本数。
  使用显式时间边界的 RectangleMark 防止孤立柱扩展至未知时段。空白是未知，
  点为有效零值；记录存在也可能只覆盖该时段部分时间。范围筛选只影响接口
  分时图，饼图／排行明确为今日累计。
- 源码 schema v6 仅新增 interface_usage_minutes。单个服务 store actor 将有效
  连续接口增量的分钟汇总与独立日汇总原子提交；基线不产生分钟记录。分类、
  日期隔离，重启保留，日切清理；不回填旧汇总或间断，不记录逐次采样和内容。
  新分钟数据随现有分类快照传给 UI，旧 IPC 缺字段显示未支持，不猜测零值。

环境与官方依据：沿用 Swift tools 6.0／最低 macOS 14，实际 Xcode 27.2、Swift
6.4.2、SDK 27.2。Apple SectorMark、chartXSelection(value:) 的官方 JSON 均确认
macOS 14 起可用；分时矩形依据 RectangleMark 的四个 PlottableValue 范围参数，
不能将 BarMark 的固定 CGFloat 范围参数当成时间范围。SQLite CREATE TABLE
官方参考已下载至 `.artifacts/minute-schema-sqlite-reference.html`。设计及来源详见
ui-implementation.md 与 database-design.md 的 v6 章节。

验证：新增 15 个针对性测试（Store 8、App 6、Agent 1），覆盖分类分钟累计、
有效零／无观测、分钟边界、重启、无效日期、原子溢出回滚、v5 升级保留及迁移
失败重试、双类别日清理、schema 约束、分时范围／25 小时日／重复与无效数据、
饼图尾项分母，以及模拟采样的基线／间断／切网与分类 IPC 数据。1440 行代表性
分钟数据的 EXPLAIN QUERY PLAN 为复合主键 INDEX SEARCH，无全表扫描或临时排序。

全量回归在本次源码快照上通过 310 项（XCTest 37、Store 76、Platform 65、Core 9、
App 89、Agent 34），日志 `.artifacts/usage-time-charts-tests.log`。之后对“最近一小时”
按分钟对齐的展示微调，重新编译及相关 29 项检查通过，日志
`.artifacts/usage-time-charts-targeted.log`。git diff --check 通过。并行会话仍在改偏好
窗口和其他功能，上述结果不是这些后续修改的最终签名／安装／整体验收结论。

本任务未修改生产数据库、未启动或暂停真实采集、未替换 /Applications 安装包；
未生成热点下载／上传／测速流量。真实安装迁移、图表指针交互和视觉走查、Intel
构建／签名及 CPU／写入性能尚未在本轮验证。旧安装版的 build 2／schema v5 证据
仍是上次分类功能的记录，不能宣称本次图表已安装。后续整体安装必须先暂停并
备份、使用更高 build 号和完整签名包，沿用严格 XPC 身份验证，不覆盖单个文件。


## 菜单栏占位缩减（2026-11-05）

已通过当前安装版真实通用设置关闭“菜单栏显示用量”，原生 UI 回读 Value: off；
状态项现在按既有偏好只保留图标，重开保留此选择。未改变采集、登录项、通知
或数据库。当前运行版界面报告 build 2，本任务未覆盖安装包或重注册服务。

源码同步实现紧凑数值：UsageFormatter.compactBytes 采用十进制整数舍入，输出
如 626M、1.2G，最多四个 ASCII 字符，未知为 —；状态项不再重复类别和“已保留”，
间距 4 -> 2 pt。完整类别、单位、保留状态和计量说明仍通过 tooltip、面板和
独立 accessibilityLabel 呈现，图标既有淡化规则保留。开关偏好继续沿用原 key；
用户日后开启用量文字时，紧凑格式须在包含本次改动的新应用中生效。

按展示改动范围更新已有断言，未新增测试框架或采样逻辑。编译和相关 76 项
既有检查通过（Store 19、Platform 26、App 18、Agent 13），日志
`.artifacts/compact-menu-bar-tests.log`；git diff --check 通过。未生成真实流量，
未做本次数值格式的安装／签名验收。


## 2026-11-05：独立偏好设置窗口

菜单栏已精简为快速概览，独立原生窗口集中应用列表、图表、详情、预警设置／记录、通用设置及说明；支持标题栏拖动、调整大小、位置记忆及单实例复用，关闭窗口不改变后台采集。保存反馈维持固定底栏，避免重新引入滚动抖动。入口与技术边界见 `ui-implementation.md`。最终集成回归 310 项通过，原生窗口与滚动稳定性测试通过；本机 build 3 已安装并通过签名及暂停 XPC 自检，旧数据核对保留。实际鼠标拖动因桌面控制连接超时未自动验收，Intel 仅编译，未上机运行。


## 菜单栏面板直接展示用量前三（2026-11-05）

已完成源码实现：所选类别的有效用量前三项显示在今日接口总量下面，包括
普通应用及完整列表已有的 Clash 来源。直接复用统一列表数据和行组件，不查
新接口、不写数据库；只增加 compact 展示参数、限三项派生值及应用详情跳转。
普通应用点击打开现有唯一偏好窗口中的对应详情；Clash 点击沿用来源说明。
没有有效正用量时显示等待／暂无记录说明，不把未知用量显示为零或填充虚假排名。
前三项仅作归因展示，不与接口总量相加，不混合两类网络账本。

编译及 7 项相关既有测试通过，包含分类切换、代理来源一致性、真实 NSHostingView
紧凑面板尺寸／长反馈不变形、原生偏好窗口复用和原应用列表渲染；日志
`.artifacts/top-usage-menu-tests.log`。面板几何上限按新增三个固定紧凑行调整为
680 pt，宽度仍为 360 pt，反馈前后尺寸相等的断言保留。git diff --check 通过。
本任务未启动、暂停或生成采样流量，未改生产库／偏好，也未替换安装包；当前
运行版需整体更新后才会显示前三项。并行会话正在改图表悬停提示，本轮不覆盖
其文件或将其后续变更视为已经验收。

## 2026-11-06 严格当天留存及本地旧数据清理

- 用户明确要求仅留存当前自然日统计，替换原有未结算租约跨日保留例外。非当前日期的应用用量、接口日/分钟汇总、预警事件、通知去重和租约统一事务删除；源代码并行新增的 schema v7 应用分钟表也纳入此规则。应用身份、额度规则、两类全局配置和偏好保留。
- SQLite 连接启用并回读 secure_delete=ON，清理后执行 WAL TRUNCATE，busy/失败可见并重试。新增 AgentRetention 独立 30 秒检查，暂停及无面板时继续运行，停机时取消；启动/恢复补清，跨日清掉内存归因和窗口。关机/休眠/服务未运行不能在午夜执行代码，不宣称任何存储介质或系统备份安全擦除。
- 清理前正式库已经只有 2026-11-06 记录。已删除 20 份旧备份/诊断 SQLite、14 个边文件、9 个旧 DMG、37 个旧应用副本及 9 个观测文件；随后补清 2 份诊断用量快照、旧 Intel 产物和设置预览包。保留源码、迁移测试资料和通用编译缓存。安装过程的临时回退应用均已删除，没有为本次清理备份流量库。
- 旧同 build 4 登记曾连续三次 XPC 超时。系统日志明确报告 OS_REASON_CODESIGNING / Launch Constraint Violation，静态签名验证通过。递增本地 build 至 5，定向注销旧副本并刷新安装版登记后，官方 SMAppService 重注册及双向 XPC 暂停自检成功；未隔离各恢复动作的独立影响。当前 /Applications/Flow Quota.app 为 0.1.0 build 5，原采集开关已恢复，启动暂停环境已还原。未发布远端版本。
- 已部署的当天留存变更通过 77 项 Store + 41 项 Agent 测试；最终 Agent 停机顺序调整后再次通过 41 项。arm64 构建及严格签名检查通过。正式库 integrity_check=ok，foreign_key_check 无错误，核对时全部日期表仅含 2026-11-06 或为空，WAL 长度为 0；两类全局配置仍为 2 行。未产生热点验收流量，也未等待一个真实午夜做实测。
- 项目 .artifacts 最终仅保留当前 arm64 应用产物，无 SQLite 流量备份、DMG 或旧回退应用。历史章节中提到的安装备份位置已在本次清理，属于过去验证记录，不表示那些备份仍存在。并行开发的新分时功能不属于上述已部署包验收。

补充源码并行边界：后续全包重编译被并行图表改动引用不存在的 AppState.snapshotUsable 阻塞，未把该源码包安装或声称全包通过。使用临时 SwiftPM 包直接链接当前 Core/Store 源码及原始留存测试（无替代实现），独立验证 schema v7 应用分钟表与其余六表的严格当前日留存、时钟回退、配置保留、WAL 截断与重开；1 项集成测试通过。临时测试包已删除。此限制不影响已安装并完成 XPC 核对的 build 5。


## 2026-11-06：用户可切换应用外观

通用设置新增“外观”三态选择：跟随系统、浅色、深色。统一保存到本机 UserDefaults，应用启动时恢复；选择立即更新偏好设置与菜单栏面板使用的外观。AppKit 负责原生窗口外观，两个 SwiftUI 根视图分别观察同一偏好；切回跟随系统时撤销两层固定外观。未更改 macOS 系统设置、服务计量逻辑或数据库结构。官方 API 与 SDK 依据见 `ui-implementation.md` 的应用外观章节。

两个定向测试通过：三种偏好可重新读取、非法值回退系统，以及 AppKit 深浅外观切换后能撤销覆盖。arm64 构建与严格签名检查通过，0.1.0 build 11 已替换安装，暂停 XPC 自检成功。原生界面已实际检查浅色、深色及恢复跟随系统，窗口标题栏与内容同时更新，导航保持在通用设置；结束时界面显示采集中，启动暂停环境与原值一致。本次未生成热点实验流量，未创建流量数据库备份，安装临时旧应用已移除。菜单栏面板接入统一偏好，未单独截图验收其三种外观，也未修改系统外观来验证系统自动切换；未进行 Intel 实机验收。


## 2026-11-06：移除单应用筛选及空白分隔卡片

按用户要求删除图表单应用选择器、相应状态及整行筛选卡片，时段查询固定覆盖当前类别全部应用；柱图与上传／下载饼图仍使用前十应用和“其他应用”，保留时间范围及网络类别选择。方向说明与信息图标移到柱图标题。同步更新 AGENTS.md；服务接口、数据库结构及计量行为不变。

移除通用设置三条、应用详情两条独立分隔线，解决分隔线单独获得卡片样式产生空卡片的问题。保留实际卡片内部必要分隔，并为公共组件注明直接子项的卡片语义。

arm64 编译、签名及 diff 空白检查通过；0.1.0 build 12 已安装，暂停 XPC 自检成功。原生界面确认通用设置没有横线空卡片，图表筛选行已删除，全部应用柱图与双饼图已加载。已将安装前开启的采集开关恢复开启，并还原临时启动环境。安装临时旧应用已删除。未生成实验网络流量，未新增数据库备份；本次低风险展示调整未新增专用测试。


## 2026-11-06：图表按应用用量列表展示来源

已将普通应用列表和图表的可见来源规则集中到 SystemProcessClassification.visibleInApplicationUsage，时段排名前排除精确身份确认的 Mihomo 代理内核，普通名称沿用列表分类显示名；隐藏流量不会混入其他。MihomoMinuteHistory 从与来源列表同一批连续连接增量生成当天、按类别隔离的仅内存分钟汇总；服务在普通应用排名前合并 Clash 来源，保留独立标识和标签，统一前十与其他，柱图、tooltip、双饼图共用结果。旧时段不回填；暂停保留，服务重启或日期变化清空。详细计量和容量边界见 ui-implementation.md 与 mihomo-api.md；schema仍v7，不新增表或网络请求。

36项定向测试通过：Store6、Platform13、Core3、App7、Agent7，覆盖隐藏内核前的统一排名、其他分母、系统友好名、独立命名空间和旧IPC可选字段兼容、Clash连续观测与零量、分钟落点、分类／间断／暂停／日期回退／重启／容量、真实Agent时段查询及账本未变，以及三处图表来源一致。日志在 .artifacts/list-source-timeline/。arm64构建与严格签名检查通过，最终0.1.0 build17已安装；未验收Intel实机。

首次build16三次重注册均XPC超时，系统日志显示OS_REASON_CODESIGNING / Launch Constraint Violation，launchd登记cdhash数组为空且EX_CONFIG78；静态签名检查通过。递增build17，定向注销已知暂存旧副本并再次执行原SMAppService注册流程后，自检pausedCheck=true、serviceStatus=1，两类图表查询及真实XPC均通过；未绕过系统安全校验，也未隔离构建号和重新登记各自的独立作用。证据 .artifacts/service-repair.Hy0Xf9/，失败过程 .artifacts/service-repair.ogy9iM/。两次安装临时旧应用均已删除。已还原启动暂停环境，并通过原生开关恢复安装前开启的采集。

安装版原生图表已确认无verge-mihomo来源，包含ChatGPT（Clash）等列表式来源名称，双饼图正常加载；采用已有正常后台采样恢复状态，未为验收生成下载、上传、测速或做热点流量对照。YouTube／虎牙端到端业务归因只由模拟数据验证，未做真实业务实验。统计仍是可能重叠的展示来源归因，不是物理接口总量或直连量；安装前未观测的Clash分时无法还原。


## 2026-11-06：饼图扇区连续相接

共用 UsagePieChart 的 SectorMark angularInset 由1改为0，上传／下载饼图同时取消固定间距，避免极小扇区被间隔吞没后显示为白色缺口。扇区仍按原始实际 bytes 权重绘制，未人为放大、删除或改变合计，颜色及悬停选择沿用现有实现。AGENTS.md和UI说明同步记录。

arm64编译、严格签名、diff空白检查及安装后的真实XPC暂停自检通过，已安装0.1.0 build18，证据 .artifacts/service-repair.nnfqeK/。启动临时环境已还原，原生界面已确认采集中，安装临时旧应用已删除。尝试查看饼图时前台页面多次变化并最终关闭窗口，未完成本次原生饼图最终截图验收，不将尝试视为视觉验收通过。此单参数展示调整未新增或重复运行单元测试；未生成实验网络流量或创建流量数据备份。


## 2026-11-06：普通连接入口恢复覆盖升级后的旧服务

用户从公开 DMG 安装 0.1.2（内部 build 23）后无法连接。此前只读诊断确认后台仍运行 build 21，XPC 日志记录 `Received message forbidden due to code signing requirement`。原连接入口将 SMAppService 的 `enabled` 当作可继续使用服务的充分条件，跳过重新注册。

`AgentClient.enableAgent()` 现先通过原签名校验路径读取服务快照；仅在当前提醒版、无 SystemExtensions 且发生 XPC 传输中断或超时时，等待旧服务异步注销完成后重新注册，并再次验证快照，最后等待开始采集 ACK。每次明确连接操作最多替换一次；持续失败保留错误及诊断入口。业务错误、无效响应、取消、系统待授权不会触发替换；开始采集 ACK 丢失也不会自动重试这个变更请求。后台刷新、查询与保存规则均不触发恢复。显式暂停修复共用该流程，但仍要求专用暂停启动环境且不发送开始采集请求。

保留双向代码身份要求，注册前验证嵌入 helper 的静态签名；未来含网络扩展的构建仍不得借此重启引擎。无数据库结构或计量语义变更；实际服务重启仍重建采样基线，不能回填间断流量，内存 Clash 累计按既有边界重新观测。官方依据见 `official-references.md` 对应节。

新增 18 项回归（17 项恢复流程、1 项 XPC 错误分型），覆盖旧 helper 身份拒绝／超时、正常连接、首次安装、授权撤销、单次恢复上限、注销／注册失败、业务和协议错误、ACK 丢失、取消、禁止替换的构建、暂停修复及恢复后的重复连接。全量 Swift Testing 362 项和 XCTest 37 项通过（包含工作区现有的独立控件测试）；日志 `.artifacts/agent-recovery-full-tests.log`。Apple Silicon 与 Intel 的 release 构建、严格 ad-hoc 签名检查及发布包静态审计均通过；日志 `.artifacts/agent-recovery-build-arm64.log`、`.artifacts/agent-recovery-build-x64.log`。两份包仅用于本地验证，未变更版本配置或上传。

本轮验证不替换 `/Applications` 的应用、不操作本机服务注册或生产数据库；未做真实旧进程覆盖安装复验，也未生成热点实验流量。GitHub 现有 DMG 尚未包含此次修复，本轮未执行发布。


## 2026-11-06：发布 0.1.4 与纯版本 tag

本次发布包含上述后台服务连接恢复修复。按用户补充要求，GitHub tag 改用 `v0.1.4`，不再附带 build 后缀；发布标题、安装包文件名和应用内版本继续仅显示三段版本。内部构建号 25 仍保存在 Info.plist 与更新清单中，供客户端比较。每个版本只对应一个不可覆盖的 tag 和安装包；重新发布必须同时递增版本号与内部构建号。

发布器与构建输入生成器使用一致的纯版本下载地址；latest 防回退按三段版本比较，同版本仍由不可变 tag 与完整附件大小／摘要校验保护。历史 tag 的一次性整理复用已验证的 DMG，不重新构建旧源码；必须先核对替代 Release 的源码指向、安装包摘要及新下载地址，再移除旧命名的 Release 和 tag。最终发布结果记录在 `public-distribution-verification.md`。

## 2026-11-06：仓库无用文件与引用清理

检查范围为清理前的 308 个 Git 跟踪文件及 3 个新增 Swift／测试文件，覆盖 SwiftPM 自动发现、应用／服务入口、配置打包、脚本调用和 Python 导入、测试资源、品牌生成与 Markdown 本地链接。已存在的图表文案、预警表格和错误可见性修改保留。

- 删除 16 个文件：`assets/brand/concepts-v2/` 的 13 个候选稿／对照图／独立生成器文件，旧 `UsageChartData.swift` 及 `UsageChartDataTests.swift`、`UsageTimelineDataTests.swift`。当前图标来自正式 `BrandIdentity.swift` 与品牌生成入口；当前图表来自应用分钟模型。清理空的旧 `distribution/public/` 目录。
- 清除被替代的接口图表聚合函数和界面未读取的辅助成员；仍被双饼图使用的值类型归入 `UsagePieData.swift`。删除清单见本地忽略目录 `.artifacts/unused-file-audit/deleted-files.txt`。
- 保留所有现有配置与脚本：版本／Info／LaunchAgent／安装提示参与打包；`.vscode/launch.json` 是显式调试入口；品牌、DMG、签名审计、版本设置、发布／恢复、暂停修复、采样诊断和测试脚本均有开发或验证用途。此次没有执行安装、采样诊断、远端发布或仓库操作。
- 保留共享额度向量、内存额度算术模型及相关回归，它们实现跨平台领域契约，不能仅因提醒版未接入过滤器就视为废弃。持久化 `BudgetLedger.swift` 的 `balance` 仍由采样入账调用，旧租约参与溢出校验并由当前日留存逻辑清理；相关 schema 与迁移保持原样。
- 唯一逐字节重复的跟踪资源是共享额度 JSON 与 SwiftPM Fixtures 副本：这是测试资源打包所需的受控镜像，由 `sync-fixtures.py --check` 及字节一致性测试验证，继续保留。其余正式品牌资源供打包、文档或同源导出使用。没有新增依赖或系统 API，删除依据为现有构建和引用关系。

验证：全量 Swift 回归 399 项通过，发布工具 Python 单测 31 项通过；Shell／Python／JSON／plist 语法检查通过，Markdown 本地链接没有失效引用。arm64 Release 构建、Agent／App 严格 ad-hoc 签名和发布静态审计通过。最终浮层测试补齐线程注解后针对性重跑通过；`git diff --check` 通过。日志位于 `.artifacts/unused-file-audit/` 的 `swift-tests.log`、`release-script-tests.log`、`build-arm64.log` 和 `tooltip-test.log`。没有生成下载、上传或热点实验流量；本次未重做 Intel／macOS 14 真机与安装验收。


## 2026-11-06：完整接口总量与不遗漏来源

主图改读当前类别既有接口分钟汇总，显示所选时段的完整上传／下载观测，独立于应用查询及 Clash API 成败。菜单栏与应用列表概览沿用接口总量；每日概览、分时明细及悬停分别核对上传和下载，不让两方向的缺失／重复相互抵销。无观测仍显示未知，已观测零量仍保留。

应用列表及分时查询取消隐藏代理内核和前十合并，所有返回身份可以滚动查看；代理内核显示“Clash 代理内核（来源应用待确认）”。悬停空间有限时明确给出项数及完整明细位置。Clash 子来源单列辅助分组，不再与内核及其他进程合计为主图总量；双饼图仅表示完整进程观测比例，明确不是接口总量的分摊。保留既有行数、来源及 1 MiB IPC 上限，容量失败明确可见，不静默删来源来使请求成功，接口记录仍独立展示。

新增独立计量比较与合成大流量回归：主图保留约 832 MB 上传＋下载，即使 Clash 仅识别约 323 MB；验证代理内核完整保留、32 项来源不截断、无应用证据／错误查询不削减接口量、方向差额不抵销，以及未知／零量、边界、重复／负值及整数溢出。查询性能样例为 128 来源 × 60 分钟，五分钟聚合返回 1,536 行，IPC 编码 192,578 bytes，继续使用已有索引。此计量修复使用既有 v6／v7 数据，不新增 schema；工作区中的 v8 预警应用证据为另一项既有改动。

最终全量测试 419 项通过：37 项 XCTest、382 项 Swift Testing（Store 86、Platform 111、Core 19、App 122、Agent 44）。日志 `.artifacts/traffic-completeness-final-tests.log`。最终补齐 Clash 无明细时的覆盖说明及双来源校验后，11 项定向界面／计量回归通过，日志 `.artifacts/traffic-completeness-final-ui-tests.log`。Apple Silicon／Intel release 构建、Agent／App 严格 ad-hoc 签名及发布包静态审计通过，日志 `.artifacts/traffic-completeness-build-arm64.log`、`.artifacts/traffic-completeness-build-x64.log`。本地构建沿用版本配置，无发布版本递增。合成数据原生截图 `/tmp/flow-quota-full-traffic-fixture.png` 已检查，总量、代理进程及上传／下载差额可读；该图明确标注模拟数据，不能作为实网归属证据。

同步更新 AGENTS、README、使用说明、设计方案、数据库查询说明与 Mihomo／系统来源说明。旧实施日志保留其历史验证事实，首页声明当前计算口径以 `traffic-accounting.md` 为准，不再把旧隐藏／合并策略当作现行要求。

当前采集输入仍不能证明每个接口字节唯一对应哪个原始应用。未恢复过去已关闭的连接，未宣称完全还原原始应用分摊，也未将接口差额伪装成某个应用的实测用量。没有修改本机统计数据库、替换 `/Applications` 的应用、重启实际服务、生成热点实验下载／上传、提交或发布代码。本轮未验证 macOS 14／Intel 真机、所有 VPN／代理组合或运营商计费误差。


## 2026-11-06：准备发布 0.1.7

版本号递增为 0.1.7、内部构建号 28，包含完整接口总量与来源展示修复，以及此前完成的 schema v8 预警应用证据。沿用已通过的 419 项 Swift 回归与 11 项最终界面／计量回归；本次发布工具 34 项 Python 单测、共享向量同步及变更凭据／产物检查通过。签名工具已确认本机钥匙串身份可用，不导出私钥。

发布说明同步描述完整总量、保留代理内核、上传／下载差额与预警明细，安装流程说明同步为用户主动触发的 Sparkle 更新。正式打包、远端附件核对与 latest 激活结果在发布完成后记录到 `public-distribution-verification.md`；本节不作为已发布证明。


## 2026-11-06：0.1.7 发布完成

源码 `fed0ccd` 已推送，`v0.1.7` 指向打包源码。双架构 DMG 与签名更新源的八个附件核验通过后已发布并设为 latest；线上小型更新入口、附件摘要和成品只读挂载检查均通过。版本为 0.1.7，内部构建号 28。详细时间、摘要及验收限制见 `public-distribution-verification.md` 对应记录。


## 2026-11-06：Clash 完整来源拆分与全系统展示

本地源码已实现 800MB=虎牙300MB+YouTube300MB+其他未识别200MB；内核仍保留原始账本和提醒身份，日常展示以子项替代父项。按分钟先核对上下行，再汇总图表桶和当天结果；方向超额、身份冲突或无明细时全部父项字节保留为未识别，不缩放、删量或从其他时段借量。物理接口总量独立，未实现原应用逐字节精确还原，也不将接口差额伪称未知应用实测。

schema 8→9 事务新增 clash_source_usage_minutes，服务在来源批次提交后推进基线。保存当天、类别、分钟、受控来源ID/名称/识别状态、整数收发字节及有效样本数，重启保留；128来源/32768单元容量失败和读写失败可见，原接口及进程采集不受 API 错误中断。旧内存分钟实现已删除，不存在两套历史。跨日及回退统一清理，secure_delete 与 WAL 截断沿用，不补填旧明细。

列表、菜单前三、时段明细、主图悬停和双饼图共用来源，移除辅助来源重复分组及常驻核对长文；原始计数、API 诊断、内核整体提醒编辑移入用量详情。新预警 JSON 保留原触发身份并冻结来源子项；短时来源只采纳被实际单调时钟窗口完整包含的区间。旧事件不回填。

最终 `scripts/test-macos.sh` 全量 **431 项通过**（37 XCTest + 394 Swift Testing）：核心25、Store91、平台110、App122、Agent46，另37 XCTest。覆盖800MB分拆、上下行冲突、分钟不互借、未观测/零量、旧数据、迁移回滚、写故障重建基线、类别、重启、日期回退、128来源/32768行容量、预警冻结及原生UI。日志 `.artifacts/clash-breakdown-full-tests.log`。同机 arm64 Swift 6.4.2、SDK27.2、系统链接SQLite3.54.0，32768单元中128来源×60分钟返回7680行，最后一次测得约1.91ms；只是临时库合成查询测量，不代表常驻CPU/内存或真实网络精度达标。

arm64及x86_64优化构建、完整应用审计及严格ad-hoc签名检查通过，日志 `.artifacts/clash-breakdown-build-arm64.log`、`.artifacts/clash-breakdown-build-x64.log`。原生模拟列表预览 `/tmp/flow-quota-clash-list-preview.png`。只构建本地产物，版本元数据仍为现有0.1.7，未创建新Release或覆盖线上附件；正式发布需递增版本与内部构建号。未安装/重启本机实际服务，未改生产数据库，未生成下载、上传、测速或热点实验流量；VPN/TUN、运营商精度和逐字节原始应用还原未实测。


## 2026-11-06：0.1.8 发布准备

用户授权推送并发布本次完整来源拆分，版本递增为0.1.8、内部构建29。发布包使用同一已提交源码构建两个架构；Release说明同步新行为，继续注明ad-hoc、未公证及计量限制。沿用八附件白名单、Ed25519签名、远端摘要核对及最后激活latest的发布流程。此前431项回归与双架构验证属于本轮源码；实际发布结果另行追加记录。
