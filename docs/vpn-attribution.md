# Clash／VPN 代理归因与身份权限

> 兼容范围（2026-11-06）：VPN／代理来源明细目前仅支持 Clash／Mihomo，实际接入 Clash Verge 的本地接口。其他 VPN／代理及未接入的其他 Mihomo 客户端不会自动出现同类明细；普通接口／进程采样不等于识别 VPN 内部来源。详见 [当前兼容范围](mihomo-api.md#兼容范围)。

> 当前流量口径（2026-11-06）：以 [流量总量与应用来源](traffic-accounting.md) 为准。主图完整显示接口用量，保留代理内核及全部已观测进程，Clash 辅助线索单列，未识别／计量差额直接说明。下文早期验收中的隐藏内核、前十合并或应用合计主图是历史实现，不再适用。

更新：以下保留 nettop 身份修复的历史证据。当前列表保留已确认 Mihomo 内核的全部观测字节，站点／原始应用（Clash）是独立辅助线索，不重复加入总量。来源细分及计量限制见 [mihomo-api.md](mihomo-api.md)。

日期：2026-11-05，Asia/Shanghai。适用：当前 macOS 提醒版，最低 macOS 14；本机 Xcode 27.2／Swift 6.4.2／SDK 27.2。不扩大到自动阻断。

## 本机诊断

只读配置显示系统 HTTP／HTTPS／SOCKS 代理为 `127.0.0.1:7897`，IPv4 默认路由为 `en0`。Clash Verge 的界面由普通用户运行，代理内核 `/Library/Application Support/clash-verge-service/cores/verge-mihomo` 由 root 运行。配置／路由检查不能证明所有 TUN、IPv6 或其他 VPN 场景均已覆盖。

诊断时 Flow Quota 处于“采集已暂停”，没有 nettop 进程；暂停期间不增加观测用量。此外，存在独立代码缺陷：普通用户 UID 501 查询 root Mihomo 的 `proc_pidinfo(PROC_PIDTBSDINFO)` 返回 0／EPERM，而 `proc_pidpath` 能返回完整路径。旧解析器在查询出生时间失败后提前丢弃进程，因此即使 nettop 提供该内核计数，也不能进入应用账本。

## 修复与计量边界

- 首选原有 BSD 进程信息接口。只有明确 EPERM／EACCES 才尝试公开的 `sysctl([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid])`，从 `kinfo_proc.kp_proc.p_un.__p_starttime` 读取出生时间。不提权、不调用私有 API；其他错误、截断数据或无效 PID／时间戳均拒绝归因。
- 两个接口使用同一秒／微秒身份 token，并在路径读取前后复核出生时间，保留进程退出和 PID 重用防护。权限变化不会制造新的基线；首次观察、间断及旧进程重新出现仍不回填。
- 已核对的完整 Mihomo 可执行路径展示为“Clash Verge 代理内核（Mihomo）”；保持独立 `exec:` 身份和原账本，与 Clash 界面进程分开。此路径分类仅辅助展示，不能作为签名认证，也不表示识别所有同类 VPN。其他路径仍可按通用可执行身份记账，无法读取身份时显示覆盖限制。
- 系统代理可能把多个应用的外部传输集中到内核，不能凭内核字节数拆回原始应用。nettop 仍仅取 external，不额外统计 loopback 来补数；代理/TUN 与应用归因可能重叠，不能把它们相加为总量。
- 顶部总量仍来自可明确选择的单个物理接口，独立于代理身份解析和应用列表。物理与虚拟接口不叠加；TUN 下无法明确物理接口时保留“不可用”，不能猜选接口或以应用合计代替。
- 无 schema 变化、不清库、不重置现有用量和规则；修复不能追溯此前漏掉的代理流量。

## 官方依据与验证

公开依据为本机 macOS SDK `usr/include/libproc.h`、`sys/proc_info.h`、`sys/sysctl.h` 及 `sys/proc.h`。其中 `sys/proc.h` 明确标注 `Exported fields for kern sysctls` 和 `__p_starttime`；`KERN_PROC_PID` 与 `kinfo_proc` 均在公开 SDK 中。访问权限的实际结果来自本机当前普通用户检查，并非对所有系统进程的可读性承诺。

`.artifacts/vpn-diagnosis/mihomo-metadata.json` 保存原接口权限错误；`mihomo-birth.json` 保存 sysctl 成功结果。链接本轮测试构建的真实 Platform／Core 模块后，`production-resolver.json` 显示 UID 501 已解析 root Mihomo 的完整 `exec:` 身份及 sharedProxy 展示分类。该检查只传入测试用零计数以执行身份路径；`network_counters_read=false`、`ledger_written=false`，没有使用真实流量或写生产库。

自动测试覆盖权限回退、API 错误、响应长度／PID／时间戳、身份一致性、路径失效、进程退出／重用，以及模拟代理增量→独立账本→短时预警。没有启动 nettop、生成下载／上传／测速或做热点对照；未验证真实 VPN 字节归因、运营商误差、所有 TUN／IPv6 配置、macOS 14 或 Intel 实机表现。最终构建及安装状态以 `implementation-status.md` 的本轮记录为准。
