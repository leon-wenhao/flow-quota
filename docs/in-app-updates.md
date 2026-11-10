# 应用内更新

Flow Quota 使用 Sparkle 2.10.1（SwiftPM 精确锁定，macOS 14+），首次安装仍是 DMG 拖拽，后续由“检查更新”打开标准更新界面，下载、验证、安装并重启。2026-11-09 起默认开启自动版本查询，通用设置可关闭；查询不自动弹窗、下载或安装。

## 自动版本查询（2026-11-09）

本机偏好保存自动检查开关（默认开启）、最近尝试和最近成功时间。复用主应用原有 1–5 秒轮询，启动至少 30 秒后检查；成功后 24 小时才再次检查，失败至少间隔 1 小时重试。重启保留间隔；唤醒后在下一轮补做已到期检查，日期回退不被未来时间戳永久阻塞。普通网络、热点／高成本网络、网络状态未知以及暂停采集均不阻止查询。网络不可用时按失败处理并在“关于”页展示错误。关闭自动检查不取消已发出的查询，后续不再发起；手动检查不受开关或间隔限制。

GitHub 优先和一次 Gitee 回退均在主线程调用 Sparkle 2.10.1 的 `SPUUpdater.checkForUpdateInformation()`，只查询 appcast 并通过 delegate 更新版本提示；Sparkle 自身会忽略用户已跳过的版本。查询中、安装交接、服务恢复或其他服务操作中不会启动另一次自动查询。找到新版在菜单栏面板显示“有新版本”，关于页显示版本信息；不激活应用、不弹更新框、不下载包。用户点击“检查更新”时先静默确认可用源，成功后在同源打开标准交互流程；两端失败则回到关于页显示错误。失败信息保留在关于页，成功查询后清除。

`SUEnableAutomaticChecks` 和 `automaticallyChecksForUpdates` 继续为 false，用来禁用 Sparkle 自带的后台交互式检查；应用自有调度只允许 `.updateInformation`，拒绝 `.updatesInBackground`。自动下载／安装及系统信息上报继续关闭。更新优先 GitHub，失败后尝试 Gitee `codex/update-feeds` 分支的固定架构签名清单（`updates/appcast-arm64.xml` 或 `updates/appcast-x86_64.xml`），不读取 Release 正文或 ready 标记；正常无更新不回退，签名校验保持不变。0.1.13 已双端发布；Gitee 八项附件及固定清单匿名回读通过，GitHub latest 已激活。真实客户端跨版本安装及不同国内网络可达性仍待验收。检查时间属于通用偏好，不涉及统计数据库或 schema。

官方 API：Sparkle `SPUUpdater` 的 `checkForUpdateInformation` 文档（https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html），并核对固定依赖 2.10.1 的 `SPUUpdater.h`、`SPUUpdateCheck.h` 与 `SPUUpdaterDelegate.h`。该 API 要求主线程，只通过查找／未找到／完成回调提供结果，已有会话时不启动新查询。

## 更新与服务交接

更新前采集继续运行。用户确认安装后，Sparkle 的 shouldPostponeRelaunchForUpdate 回调延迟安装交接。应用阻止其他服务修改并停止轮询，读取已注册服务的最新状态，保存本机恢复标记，确认 stopProtection，再等待 SMAppService.unregister 异步完成。只有全部成功才调用 Sparkle 安装 continuation。失败回到关于页展示错误和重试入口，不交付 continuation。Sparkle 已解包准备好的更新可能在退出时继续安装，因此应用退出路径也必须经过同一交接，禁止走“仅退出界面”分支。

新应用启动时在轮询前处理恢复标记。后台服务只要发现标记就以暂停状态启动；应用确认注册成功后才按原状态发送 startMonitoring 或 stopProtection，成功后删除标记。未启用过的服务不会因更新启用。标记包含源构建、目标构建、原注册/采集状态及时间，24 小时后或格式错误不自动恢复，提供人工恢复入口。失败恢复同样使用这个流程。数据库不迁移、不删除、不备份；重建采样基线，升级期间不补算流量。服务重启后的内存 Clash 来源重新观测。

## 发布与信任

架构独立的 appcast-arm64.xml / appcast-x86_64.xml 在 GitHub 由 latest Release 附件提供，在 Gitee 由固定分支文件提供；两端 Release 继续保留对应清单附件用于审计。发布流程见 [双源方案](gitee-distribution-plan.md)。DMG、appcast 均使用钥匙串 local.flowquota.app 账户的 Ed25519 密钥签名；Info.plist 要求提取前校验及签名 feed。发布白名单扩展为两个 DMG、两个 appcast 及原四项元数据。旧 JSON 清单继续发布，服务已发布的 0.1.5 检查入口；旧客户端仍需手动安装一次含 Sparkle 的版本。

公钥随源码提交，私钥只保存在钥匙串，发布前必须核对二者匹配，禁止自动换钥。build 脚本复制 SwiftPM 下载的 Sparkle.framework，保留官方框架的嵌套签名，对外层应用进行 ad-hoc 签名并逐文件审计预期框架。Sparkle 的许可证随框架保留。当前为 ad-hoc，未公证，可能出现系统权限或 Gatekeeper 提示，不能承诺无系统提示。

## 更新后服务注册修复（2026-11-06）

更新替换包含 LaunchAgent 可执行文件时，恢复流程在每次注销后重新注册前，先对当前完整 `.app` 执行一次强制 LaunchServices 登记，再调用 `SMAppService.register()`；只有服务实际通过 XPC 自检后才恢复采集并清除恢复标记。这样处理的是系统保存的应用包路径与启动约束元数据，不依赖用户手动刷新或反复点击连接按钮。

如果登记、注册或 XPC 自检任何一步失败，仍保持暂停、保留恢复标记并显示可重试错误；不会把“注册成功”当成后台已可用，也不会自动启用原本未启用的服务。修复覆盖首次安装、更新后恢复、旧服务连接失败后的替换注册及暂停恢复路径。

本机已用同一套代码恢复 0.1.8 的后台服务，界面确认“应用采集中”，更新按钮恢复可用；没有改动统计数据库或补算服务中断期间的流量。

## 官方依据与验收边界

- https://sparkle-project.org/documentation/ ：Ed25519、签名 feed、提取前验证；2.10.1 的 SUUpdateValidator.m 明确允许有效 EdDSA 下使用 ad-hoc 签名。
- https://sparkle-project.org/documentation/package-manager/ ：SwiftPM 二进制包不含命令行签名工具，工具使用同版本官方发行包。
- https://sparkle-project.org/documentation/customization/ ：SPUStandardUpdaterController 与自定义更新策略。
- https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SPUUpdaterDelegate.h ：延迟安装 continuation、更新完成及失败回调。
- https://developer.apple.com/documentation/servicemanagement/smappservice/unregister() ：等待后台进程终止后交接。

本地使用模拟服务、临时偏好、离线签名文件验证生命周期与发布元数据，并编译两种架构、检查签名及运行时链接。真实跨版本安装、不同用户权限/Gatekeeper 及 Intel 真机运行需独立验收，不能由编译或模拟结果代替。

## 2026-11-06 本地验证记录

- Swift 测试：5 个目标共 363 项通过，覆盖停止/注销确认、交接等待、活动/暂停状态恢复、未注册服务不启用、错误保留与重试、过期/损坏标记及 Sparkle 可识别的 ObjC 委托选择器。
- Python 发布测试：34 项通过，包括更新源架构/版本/白名单与签名结构、RFC 8032 公钥验证及篡改拒绝、发布顺序和内部构建号递增检查。
- arm64、x86_64 Release 构建、原生最低系统版本、内嵌框架逐文件校验、嵌套及外层签名检查均通过。
- 本地生成两个 0.1.6 / 27 预览 DMG，仅覆盖构建参数，未修改正式版本文件；两个 DMG 均只读挂载并复查应用。真实 DMG 和两个 appcast 经钥匙串签名后，以提交公钥独立验证通过。预览清单刻意使用全零 sourceCommit，不能作为正式发布源码；未上传 GitHub。
- 现有 0.1.5 磁盘仍挂载，所以使用新预览版本验证打包，未操作用户原挂载。没有安装或替换本机现有应用，没有启动采集或执行热点流量实验。
- 尚未验收：真实跨版本自动替换及重启、实际 LaunchAgent 注销/重注册与系统提示、macOS 14 和 Intel 真机运行。这些结果不能由模拟服务、编译或只读 DMG 审计代替。

## 双源发布与回退（2026-11-09）

入口、凭据、完整性核验、激活标记与重试方式见 [双平台方案](gitee-distribution-plan.md) 和 [发布流程](release-macos.md)。自动检查失败后只保留可见错误，后续按至少 1 小时间隔重试，不循环切源；用户重新手动检查从 GitHub 开始。
