# 提醒版实施与验证记录

更新：2026-11-05，Asia/Shanghai。当前为 macOS 自用的流量采样统计与阈值通知，暂不自动阻断。本轮在独立接口总量之上加入后台大流量预警，严格遵守用户“不用热点流量做实验性验证”的限制。未来阻断仍需单独实现与验收。

## 用户选定 C「流量刻度」图标（2026-11-05）

第二轮三方案中用户明确选择 C。已将深青底板、薄荷绿圆角用量柱和分离阈值圆点接入 `BrandIdentity.swift`，应用 ICNS、窗口标题标记和菜单栏复用相同矢量源。SVG 导出与 SwiftUI 同用几何和配色；正式 1024 PNG 与选定的 `concepts-v2/C-meter.png` SHA-256 完全一致。原 A／B／C 提案保留供比较。

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
