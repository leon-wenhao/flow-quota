# 官方依据与工具链

验证日期：2026-11-04。本地 Xcode 27.2（27B52）、Swift 6.4.2、macOS SDK 27.2；deployment target macOS 14。脚本通过 DEVELOPER_DIR 选择 Xcode，不修改全局 xcode-select。

## Apple

- [TN3134 Network Extension provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)：内容过滤器部署类型及分发条件。
- [Installing System Extensions and Drivers](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers)：激活期间校验代码身份和 entitlement。应用打开与扩展激活分别验证。
- [NSXPCConnection](https://developer.apple.com/documentation/foundation/nsxpcconnection)：接口、生命周期、错误与失效处理。SDK `NSXPCConnection.h` 明确 `setCodeSigningRequirement` 自 macOS 13 可用；双方在 resume 前设置需求，不通过可猜测的名字信任调用者。
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)：LaunchAgent plist 放在 app 的 Contents/Library/LaunchAgents，使用 BundleProgram 解析应用内路径。
- [Bundle](https://developer.apple.com/documentation/foundation/bundle)：使用运行时 Bundle 的 executableURL 获取实际可执行文件位置，不依赖 launchd 传入的相对 argv[0]。
- [NWPath.isExpensive](https://developer.apple.com/documentation/network/nwpath/isexpensive)：系统高成本信号用于自动计量，不宣称确认手机热点；普通网络保留手动标记。2026-11-05 经用户批准更新。
- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)：菜单栏 window 样式与原生生命周期。
- SDK `NEFilterFlow.h`：sourceAppIdentifier 在 macOS 不可用，应验证 sourceAppAuditToken；不能直接照搬 iOS 示例或用 PID 当持久身份。
- SDK `NEFilterDataProvider.h`：分块数据判定、offset、UDP 恢复约束与已有流更新。未实测前不声称已实现阻断。

## 图表与版本检查（2026-11-05）

- [Swift Charts](https://developer.apple.com/documentation/charts)：当前 macOS 14 目标使用系统图表框架；图表只展示现有快照，不保存采样流水。
- [URLSession](https://developer.apple.com/documentation/foundation/urlsession)：版本清单通过 HTTPS 异步读取；请求失败、非 2xx 和无效 JSON 均显示为检查失败。
- [Bundle](https://developer.apple.com/documentation/foundation/bundle)：当前应用版本从 `CFBundleShortVersionString` 和 `CFBundleVersion` 读取。

## Swift 与 SQLite

- [Swift Package manifest](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)：工具版本、平台、target、systemLibrary 和测试资源声明。
- [Swift concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)：actor 隔离和 Sendable；跨队列可变状态需同步。
- [SQLite foreign keys](https://www.sqlite.org/foreignkeys.html)：连接级启用外键与关系约束。
- [SQLite WAL](https://www.sqlite.org/wal.html)、[PRAGMA](https://www.sqlite.org/pragma.html)：单写入连接、事务持久性和 busy timeout。
- [SQLite transactions](https://www.sqlite.org/lang_transaction.html)、[EXPLAIN QUERY PLAN](https://www.sqlite.org/eqp.html)：迁移事务、查询与索引验证。

网络内容和用户流量不进入文档或日志。这里列出实现依据；实际支持与性能以 implementation-status.md 中的实测为准。

## 本地打包工具依据

本机 macOS 27.2 的 `diskutil image create from --help` 已核对，生成文件夹镜像使用 `--volumeName` 和 `--format UDZO`。构建脚本在 macOS 27 及以上使用该官方入口；较早系统保留 hdiutil 的文件夹镜像入口。开发 DMG 的实际生成结果与校验值见进度记录，不把打包成功等同于保护能力完成。


## 提醒版采样依据（2026-11-04）

- 本机 Apple `/usr/share/man/man1/nettop.1`：`-P` 按进程汇总、`-L` CSV、`-s` 间隔、`-x` 原始整数、`-t external` 非 loopback 接口类型；默认 TCP/UDP。实测重复表头用于验证解析，不把该工具内部私有框架当作可调用 API。
- 本机 macOS SDK `usr/include/libproc.h` 与 `sys/proc_info.h`：`proc_pidpath`、`proc_pidinfo`、`PROC_PIDTBSDINFO`、出生时刻字段。Swift 不导入 `4 * MAXPATHLEN` 表达式宏，按头文件定义申请路径缓冲。
- [Foundation Process](https://developer.apple.com/documentation/foundation/process)：固定可执行文件及参数、独立 I/O 队列、受控子进程生命周期。
- [Scheduling a notification locally](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)：系统接受请求与用户看见通知不同，成功调度后才确认持久化记录。
- [UserNotifications](https://developer.apple.com/documentation/usernotifications)：用户授权、状态查询、前台展示回调；应用隐藏菜单时保持独立轮询。

上述来源用于提醒版，不代表 NetworkExtension 权限、流量阻断或计费准确性已通过。

- SDK `usr/include/util.h` 的 `openpty`：本地伪终端让 nettop 的文档化 CSV 无限输出及时刷新；已实测普通管道 9 秒没有输出，伪终端持续输出正常。使用 POSIX read 独立读取，不调用私有统计框架。

## 采样 CPU 与退出修复依据（2026-11-05）

- Foundation `Process.standardInput`：显式指定子进程输入；同一伪终端 slave 用于 nettop 输入与输出，父进程只读 master，不向采样器注入按键。
- 本机 `nettop(1)` 文档化 CSV 参数保持不变。相同参数的 7 秒对照实测：stdin `/dev/null` 平均 138.93% CPU，保持打开的管道 0.43%，伪终端 0.71%，三组均持续输出 CSV。EOF 下的忙循环属于本机工具实测行为，官方文档没有承诺这一实现细节。
- 本机 SDK `usr/include/dispatch/source.h` 与 `dispatch_source_create(3)`：signal source 负责接收信号事件，不自动改变信号 disposition；`sigaction(2)` / `signal(3)` 说明 caught handler 在 exec 后重置。Agent 使用 SIGTERM/SIGINT 的空 C handler 加 DispatchSource 转交异步停机，不能使用会让采样子进程继承忽略 SIGTERM 的 SIG_IGN。
- `Process.waitUntilExit()` 与串行 I/O 队列：AsyncStream 取消不等于读循环完成；停止确认必须额外等待读循环完成、子进程退出并回收。SIGKILL/崩溃不能执行清理，不纳入正常停机保证。

## 高成本网络自动计量（2026-11-05）

- Apple `NWPath.isExpensive` 文档及本机 macOS SDK `Network.framework/Headers/path.h` 的 `nw_path_is_expensive`（自 macOS 10.14 可用）：返回路径是否使用系统认为成本较高的接口，示例包括蜂窝网络；此值不证明手机、SSID 或运营商身份。
- `NWPathMonitor.pathUpdateHandler` 在既有专用串行队列接收路径更新。先检查 `.satisfied`，再读取成本信号；未连通路径即使有成本标记也不计量。
- 产品策略经用户批准：可用且昂贵路径映射 `.expensive` 并自动计入当前每日提醒额度，显式手动标记仍映射 `.hotspot`；普通/未知路径不自动计入。每次路径更新撤销手动标记、递增内存 generation，以便采样器重建基线，绝不回补跨网流量。SSID 与定位权限不是前置条件。

## 独立接口总量依据（2026-11-05）

- 本机 macOS SDK `usr/include/net/if.h` 的 `if_msghdr2` / `ifm_data`，`net/if_var.h` 的 `if_data64.ifi_ibytes` / `ifi_obytes`（64 位 octet 计数）与 `sys/socket.h` 的 `NET_RT_IFLIST2`；通过只读 `sysctl` 路由 MIB 查询单一接口。`getifaddrs` 对应旧 `if_data` 的字段是 32 位，本次不使用它作为长期累计源，避免 4 GiB 回绕问题。
- 官方 `sysctl(3)` 和 SDK 的系统调用签名：先读取长度、限制缓冲区大小，再读取数据；接口变化导致 ENOMEM 时有限次重试，解析消息前校验长度、版本、类型与索引。读失败不返回伪零值。
- Network.framework SDK `Headers/path.h`：`nw_path_enumerate_interfaces` 只列出关联接口，`nw_path_uses_interface_type` 检查路径是否使用某类接口；不能单靠 availableInterfaces 把全部可见网卡相加。仅当路径使用的 Wi-Fi/有线/蜂窝候选唯一时选择它；不选择 loopback / `.other` 隧道，不在多个候选之间猜选。
- 接口计数描述本机链路字节，不定义运营商计费口径。局域网通信、协议开销、其他手机设备、手机自身流量与计费取整等差异仍存在；新总量不能标注为“运营商已扣费”。
- SQLite `ALTER`/新表的版本化事务迁移：schema v3 增加独立按日接口计量实体，不将应用归因行相加或制造虚拟应用；应用与接口账本分别命名。约束、回滚、主键查询计划由临时库测试验证。

用户明确禁止本轮热点实验性验证：未执行真实下载、上传、测速、运营商对照或真实接口采样验收；仅使用注入的计数/系统调用结果及临时数据库测试，加上本地编译与签名检查。真实接口支持情况和与运营商的误差尚无本轮实测结论。

## 无热点实验的安装验收（2026-11-05）

- 本机 `launchctl(1)` 的 `setenv` / `unsetenv`：只为后续由本用户 launchd 启动的进程提供环境变量；安装脚本保存并恢复原变量。`FLOW_QUOTA_VERIFY_PAUSED=1` 仅为开发包启用暂停启动，正常启动规则不改变。
- `SMAppService.register()` / `unregister()` 继续负责正式应用包的开发服务注册；XPC 双向代码身份要求保留。`AgentClient` 的暂停修复入口在修改注册前检查专用环境，既不发送 `.startMonitoring`，也不伪造采样成功。
- `--repair-agent-paused` 检查冷启动后两次真实 XPC 快照均暂停、采样时间为空且无待发通知；只验证安装/通信，不验证真实网络计量。安装后清除临时环境变量，服务保持暂停直到显式启用采集。

- Swift ObjC XPC 错误回调在任意队列执行，显式 `@Sendable` 防止继承 AgentClient 的主 actor 隔离；首次注册失败路径的动态隔离警告已复现，修复后相同失败路径不再输出该警告。参考 Swift Evolution SE-0423（Dynamic actor isolation enforcement）与本机 Foundation NSXPCConnection SDK 接口。


## 后台大流量预警依据（2026-11-05）

- 本机 Xcode 27.2 / macOS SDK 27.2 的 UserNotifications `UNNotificationRequest.h` 和 `UNUserNotificationCenter.h`：请求 identifier 用于替换或移除；再次添加已展示的相同标识请求仍可能提示。因此 UUID 稳定并不代表恰好一次展示，调度和服务 ACK 之间崩溃明确保留重复风险。继续使用既有 async `add`／通知授权与 delegate，无新增 entitlement 假设，最低 macOS 14 编译验证。
- Swift Observation 的 `withObservationTracking` 对共享投递队列错误状态做实际测试；包装类型计算属性读取内部 Observable 状态，拒绝通知时可触发观察更新。未把编译通过当作界面观察行为证据。
- SQLite CREATE TABLE CHECK／类型、事务、聚合 MAX 和复合索引规则沿用官方接口。v4 以冻结 v3 库和直接 SQL 约束／故障注入／EXPLAIN QUERY PLAN 测试核对，不靠删除库升级。具体来源与查询选择见 database-design.md v4 节。
- 时间窗口及阈值是用户批准的产品策略，单调时钟增量和当前日事务检查分别处理连续采样与日级生命周期。系统进程用途只依据本机组件元数据与精确路径，不将命名猜测标为 Apple 官方结论；证据见 system-process-classification.md。


## 应用标志与打包（2026-11-05）

- Apple InfoPlistKeyReference 的 `CFBundleIconFile`：此 SwiftPM 原生 macOS 包使用 Resources 内的 ICNS。构建先复制资源再签名，不在签名后替换图标。以 Info.plist 解析、完整包严格签名和系统图标读取核对。
- 本机官方 `iconutil(1)`：标准 iconset 转 ICNS，包含 16／32／128／256／512 点及各自 2x 图像。本机受限沙箱内工具返回 Invalid Iconset，授权在本机正常环境执行后转换成功；没有手工构造 ICNS 容器。
- Xcode 27.2 AppKit `NSImage.h`：`imageWithSize:flipped:drawingHandler:` 提供分辨率无关绘制，闭包可能在任意线程调用；`isTemplate` 让系统处理菜单栏颜色。复用同一矢量轮廓，显式 Sendable 闭包不捕获主 actor 状态。未使用已弃用的 lockFocus。
- SwiftUI `Shape`／`Path.strokedPath` 和 `ImageRenderer` 从同一几何生成界面与各尺寸图标。ImageRenderer 仅用于本机生成工具，不进入运行时采样；主应用仍按最低 macOS 14 编译。图形定义、资产与复现入口见 assets/brand/README.md。

## root 代理进程出生时间（2026-11-05）

- 公开 SDK `usr/include/sys/sysctl.h` 的 `KERN_PROC_PID`／`kinfo_proc` 与 `usr/include/sys/proc.h` 的 exported `extern_proc.p_un.__p_starttime`；结合 libproc 的 `PROC_PIDTBSDINFO`、`proc_pidpath` 校验进程出生身份。仅 EPERM／EACCES 时回退公开 sysctl，严格校验返回长度和 PID，不使用私有 flavor、不提权。
- 本机 UID 501 读取 root Mihomo 的 BSD 元数据被拒绝，sysctl 出生时间与进程路径可读，修复后的实际 resolver 已复核成功；权限行为是本机证据，不承诺所有系统可读。测试使用合成计数，没有启动采样。范围与限制见 `vpn-attribution.md`。


## 用量刷新偏好依据（2026-11-05）

- Apple SwiftUI `AppStorage`：从 `UserDefaults` 保存／恢复值，并在偏好变化时让界面失效更新；macOS 11 起可用。本次使用现有原生设置模式，不新增 SQLite 实体，符合项目最低 macOS 14。官方原文：https://developer.apple.com/documentation/swiftui/appstorage
- Apple Swift `Task.sleep(for:tolerance:clock:)`：异步等待不阻塞底层线程，任务取消时抛出 `CancellationError`；macOS 13 起可用。轮询仍只保留一个串行任务，每轮服务读取与通知处理完成后读取最新间隔再等待。官方原文：https://developer.apple.com/documentation/swift/task/sleep(for:tolerance:clock:)
- 本机工具链：Swift 6.4.2、macOS SDK 27.2。偏好默认 5 秒，可选 1–5 秒，保证通知检查间隔不比原版更长，并保留快照 15 秒失效语义；该范围是产品实现约束，不是系统 API 限制。后台两种采样仍约每 2 秒，1 秒刷新不保证每轮都有新计量值。


## 连续单调采样时钟与短时窗口修复（2026-11-05）

- Apple `DispatchTime.uptimeNanoseconds` 官方定义排除系统休眠时间，不能作为本项目睡眠间断识别的唯一时钟。官方原文：https://developer.apple.com/documentation/dispatch/dispatchtime/uptimenanoseconds （审查缓存 `.artifacts/alert-audit-20261105/apple-dispatchtime.md`）。
- 本机官方 `clock_gettime(3)`／`clock_gettime_nsec_np(3)` 手册：`CLOCK_MONOTONIC` 包含系统休眠；`CLOCK_MONOTONIC_RAW` 同样连续递增且不受时间或频率调整影响，不能与其他时钟基准混用；`CLOCK_UPTIME_RAW` 排除休眠。`clock_gettime_nsec_np` 返回 64 位纳秒，API 自 macOS 10.12 提供。
- Xcode 27.2 / macOS SDK 27.2 `usr/include/_time.h` 的公开常量和 availability 声明确认上述 clock id 及函数，适用于项目最低 macOS 14。`SamplingClock` 集中读取 RAW 连续时间，`NettopParser` 和接口采样共用；应用与接口累计器及滚动窗口继续接受显式纳秒以支持纯模拟测试。
- 使用官方时钟前后读数包围默认 parser 时钟的测试核对时钟来源；以注入的包含休眠时长的纳秒验证 8 秒断点。未让设备实际睡眠，不宣称已完成真实唤醒或各型号平台的验收。

## Mihomo 本地 controller API（2026-11-05）

- 本机当前 Mihomo 由 Clash Verge 以 `-ext-ctl-unix /var/run/clash-verge-service/users/<uid>/verge-mihomo.sock` 启动；socket 权限为当前用户 `0600`。Flow Quota 只读请求 `/connections`，不读取密钥、不修改配置。
- 公开 macOS Unix domain socket API（`socket`／`connect`／`send`／`recv`）用于本地传输；HTTP 状态、响应大小、chunked framing 和 JSON 字段均严格校验。具体响应字段以本机运行的 Mihomo 版本为准，未知字段忽略，缺失的可选进程字段显示来源未确认。
- API 归因与物理接口计量、nettop 应用计量分开；本轮不把 API 数据写入日用量表，不宣称能恢复已关闭连接或完整运营商账单。边界和证据见 `mihomo-api.md`。


### 独立偏好设置窗口（2026-11-05）

- Apple [NSWindowController](https://developer.apple.com/documentation/appkit/nswindowcontroller)：管理单个原生窗口的生命周期；应用保留同一控制器，按需显示并复用。
- Apple [NSWindow.StyleMask](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct)：使用 titled、closable、miniaturizable 和 resizable 原生窗口样式。
- Apple [NSHostingController](https://developer.apple.com/documentation/swiftui/nshostingcontroller)：在原生 AppKit 窗口承载 SwiftUI 内容。
- Apple [Window](https://developer.apple.com/documentation/swiftui/window)：核对单实例 SwiftUI scene 的行为后，本项目沿用已有 AppDelegate 的 AppKit 窗口管理方式，便于菜单栏及 `--window` 统一入口、避免重复设置窗口。
- 适用项目最低 macOS 14；本机 Swift 6.4.2／macOS SDK 27.2，arm64 及 x86_64 编译。原生窗口 fixture 测试使用假服务，不产生网络采样流量。


### Clash 来源列表（2026-11-05）

- 本轮成功读取并核对 Mihomo **v1.19.33** 官方源码：`constant/metadata.go`（host/sniffHost/processPath；RuleHost 优先非空 sniffHost）、`hub/route/connections.go`（只读 GET 连接快照）、`tunnel/statistic/tracker.go`（连接 ID、计数、链和关闭生命周期）。固定版本链接、产品站点分类表与降级行为见 `mihomo-api.md`。
- 应用列表显示 API 聚合的站点／原始应用（Clash），DIRECT 也表示由 Clash 处理，不从未知链名猜测节点类型。应用路径按既有规则分组，不把 API 提供元数据当作签名认证身份。
- 本次为独立展示口径，不改 nettop 日账本和接口总量，不新增代理表。关闭连接、暂停、失败恢复和网络类别隔离以模拟 API／临时数据库验证，不生成网络实验流量。


### Swift Charts 悬停提示（2026-11-05）

- Apple [ChartProxy.plotFrame](https://developer.apple.com/documentation/charts/chartproxy/plotframe)：绘图区 frame 的 anchor，可能为 nil；macOS 14 起可用。
- Apple [ChartProxy](https://developer.apple.com/documentation/charts/chartproxy)：使用 `value(atX:)` 从绘图区横坐标取时间，`position(forX:)` 定位时段中心。
- Apple [onContinuousHover](https://developer.apple.com/documentation/swiftui/view/oncontinuoushover(coordinatespace:perform:))：以进入、连续移动和退出的阶段管理浮层；浮层禁止命中测试，避免遮挡底层跟踪区。
- 实现与本机 Swift 6.4.2／macOS SDK 27.2 编译检查一致，项目最低 macOS 14；Intel 仅交叉编译，无真实 Intel 鼠标交互验收。

## 2026-11-06 当天留存维护

- SQLite PRAGMA secure_delete（https://www.sqlite.org/pragma.html#pragma_secure_delete）：连接启用 ON，清理删除单元；不把逻辑删除宣传为系统备份或存储介质安全擦除。
- SQLite PRAGMA wal_checkpoint（https://www.sqlite.org/pragma.html#pragma_wal_checkpoint）：清理事务提交后使用 TRUNCATE，检查返回的 busy 标记；失败保留重试状态。
- 后台日期检查沿用项目已使用的 Swift Task.sleep(for:) 和取消机制；30 秒只检查日期，成功清理后不每次采样截断 WAL。
- 工具链仍为 Swift tools 6.0、最低 macOS 14，本机 arm64 编译与临时数据库测试验证；真实热点流量未用于验收。

## Application timeline / directional pies (2026-11-06)

- Apple Swift Charts `ChartProxy.angle(at:)`: https://developer.apple.com/documentation/charts/chartproxy/angle(at:)
  Point is plot-relative; 12 o'clock = zero, clockwise positive.
- `ChartProxy.value(atAngle:as:)`: https://developer.apple.com/documentation/charts/chartproxy/value(atangle:as:)
  Converts the above angle to a sector-domain value; nil is not a valid sector.
- `ChartProxy.plotFrame`, `value(atX:)`, `value(atY:)`, `RectangleMark`, `SectorMark`:
  https://developer.apple.com/documentation/charts/chartproxy
  https://developer.apple.com/documentation/charts/rectanglemark
  https://developer.apple.com/documentation/charts/sectormark
  Uses explicit x/y ranges for the paired stacks; the sector/tooltip overlay never
  participates in the chart data domain. SDK declarations and compilation verify
  availability at the project's macOS 14 minimum (Swift tools 6.0).
- SQLite v7 uses the existing transaction/FK/integer-validation policy; no new
  SQLite API or dependency. Range scan and aggregate query plans are fixture-tested.

Apple's DocC JSON for the two angle methods was read directly, in addition to
local SDK declarations. Actual native sector hover and data preservation are
recorded in ui-implementation.md after installation; simulations are not traffic
measurement validation.


## 私有源码与公开二进制分发（2026-11-06）

- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)：Release、tag 与源码归档均属于各自仓库；公开资料仓库必须有独立历史，不能通过把源码仓库改为公开来分发附件。
- [gh release create](https://cli.github.com/manual/gh_release_create)、[upload](https://cli.github.com/manual/gh_release_upload)、[edit](https://cli.github.com/manual/gh_release_edit)：草稿创建、显式资产上传、`--verify-tag`、`--draft=false`、`--latest`，使用本机 gh 2.103.3 官方帮助核对参数。
- [Release assets API](https://docs.github.com/en/rest/releases/assets#get-a-release-asset)：使用返回的文件名、上传状态、size 和 sha256 digest 核对上传结果，不为验收重新下载 DMG。
- [Python 3.9 hashlib](https://docs.python.org/3.9/library/hashlib.html)：标准库分块 SHA-256；本机系统 Python 3.9.6，不引入 pip 依赖。
- 本机 Apple `strip(1)`：`-S` 去调试符号、`-x` 去本地符号，复制到 app 后、ad-hoc 签名前处理。公用包不得带 .dSYM 或调试源码路径。
- [Apple 安全打开 App](https://support.apple.com/zh-cn/102445)：说明当前 ad-hoc、未公证，使用正常的单应用打开入口；不提供停用 Gatekeeper 的指令。

验证结果及尚未完成的分发限制见 `docs/public-distribution-verification.md`。

- [Git Trees API](https://docs.github.com/en/rest/git/trees)、[Git Commits API](https://docs.github.com/en/rest/git/commits)、[Git Refs API](https://docs.github.com/en/rest/git/refs)、[Contents API](https://docs.github.com/en/rest/repos/contents)：空仓库先仅用公开 README 初始化，再建立白名单 blob/tree/commit；更新 ref 使用 `force: false`，避免覆盖并发提交。公开 tag 只取公开 main，绝不使用私有源 HEAD。

## DMG Finder 安装布局（2026-11-06）

- 本机 `/System/Library/CoreServices/Finder.app` 公开 scripting dictionary（使用 Xcode 27.2 的 `sdef` 导出）：`container window`、`icon view options`、`arrangement`、`background picture`、`position`、`bounds`、`toolbar visible`、`statusbar visible`，以及 `update … without registering applications`。只使用公开脚本接口，不修改系统窗口或私有 API。
- 本机 macOS 27.2 的 `diskutil(8)`、`diskutil image create from --help`：从文件夹创建命名卷；RAW 可写、UDZO 只读压缩，已有镜像可作为转换源；`image attach --mountPoint` 指定临时挂载目录。macOS 14–26 使用原有 `hdiutil create/attach/convert` 路径，尚需对应系统验证。
- Xcode 27.2 / AppKit SDK 的 `NSBitmapImageRep`、`NSImage`、`NSGraphicsContext`：背景通过系统文字与路径绘制，TIFF 同时包含 1×／2× bitmap 并指定逻辑尺寸。安装提示继续遵循上文 Apple 安全打开 App 的正常单应用入口。


## SwiftUI 控件点击区域（2026-11-06）

- Apple `View.contentShape(_:eoFill:)`：https://developer.apple.com/documentation/swiftui/view/contentshape(_:eofill:)
  已读取官方 DocC JSON：该修饰器指定视图用于 hit testing 的形状。共享分段按钮在宽高扩展后设置与可见选项一致的圆角点击形状，使未选中项的透明区域也能触发原生 Button；不添加手势替代按钮，不改变禁用与无障碍语义。
- 项目 Swift tools 6.0 / Swift 6、最低 macOS 14；本机 Xcode Swift 6.4.2、macOS SDK 27.2。
- `ControlHitAreaTests` 在原生 `NSHostingView` / `NSWindow` 中派发本地鼠标按下与抬起事件：修复前分段空白处点击可复现失败，修复后验证两项／三项分段、各共享按钮样式、整行展开入口及禁用状态。测试不连接真实采样服务，不产生验收流量；尚未在 macOS 14 真机复验。


## 覆盖升级后的后台服务恢复（2026-11-06）

- Apple [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)；已核对本机 Xcode 27.2 / macOS SDK 27.2 的 `ServiceManagement.framework/Headers/SMAppService.h`。该类自 macOS 13 可用，满足项目最低 macOS 14；头文件明确：LaunchAgent 的 plist／可执行文件更新后需重新注册，可执行文件改变时建议先注销。`enabled` 只表示已注册且有资格运行，不证明进程来自当前安装包或 XPC 可连接。
- SDK 同一头文件的 `unregisterWithCompletionHandler:`：完成回调在旧进程终止后执行，此后才可安全重注册。本次沿用 Swift 的 `try await service.unregister()`，等待后调用 `register()`，不使用不等待进程退出的同步注销替代。
- 沿用 Apple `NSXPCConnection` 的 `setCodeSigningRequirement`、错误代理与 interruption／invalidation 回调；仅将传输失败与 Agent 返回的业务错误分型，双向 designated requirement 校验不变。恢复后仍通过原 XPC 路径读取快照和等待开始采集 ACK，不能以注册状态替代连接成功。
- 验证：Swift 6.4.2 编译及模拟服务生命周期回归；真实旧进程覆盖安装后的 SMAppService 恢复尚未实机复验，不将模拟生命周期测试当作系统注册验收。未启停本机实际采样服务、未生成验收网络流量。
