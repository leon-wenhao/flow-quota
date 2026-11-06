# Clash 来源识别与列表归因

更新：2026-11-05，Asia/Shanghai。适用当前 macOS 提醒版。只读连接信息，不修改 Clash/Mihomo 配置，不负责阻断。

## 产品语义

主应用列表在同一列表内展示普通应用每日归因及 `YouTube（Clash）`、`虎牙直播（Clash）` 等来源行。代理行右侧标注“本次代理观测”，点击查看上传、下载、来源应用和边界，不进入每日额度编辑。独立代理流量卡片退出应用列表；用量详情仅提供来源识别诊断。暂停文案明确指 Flow Quota 采集，不代表 Clash 已暂停。

“（Clash）”表示连接由 Clash/Mihomo 处理，包含其 DIRECT 规则，不表示一定经过代理节点。普通应用行依然是 nettop 日账本，不能声称已经扣除其中代理流量。已确认的 Mihomo 内核不作为普通应用行展示；原账本和既有提醒规则不删除。

## 官方依据和接入

本机已有只读验证确认运行 Mihomo v1.19.33。对应版本官方源码：

- [controller 连接路由](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/hub/route/connections.go)：`GET /connections` 返回当前连接快照；其他删除路由不调用。
- [连接元数据](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/constant/metadata.go)：JSON 字段 `host`、`sniffHost`、`process`、`processPath`。`RuleHost()` 在存在 sniffHost 时使用它。
- [连接计数与链路](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/tunnel/statistic/tracker.go)：连接 ID、upload/download、metadata、chains。连接关闭会离开活动集合，不能据后续快照还原已丢失的来源增量。

本轮从官方 GitHub contents API 成功读取上述三个固定版本文件并核对字段；不依赖第三方文章。当前 Clash Verge 使用用户拥有的 Unix Socket：

```text
/var/run/clash-verge-service/users/<uid>/verge-mihomo.sock
```

生产客户端使用 macOS 公共 Unix domain socket API，校验 HTTP 状态、chunked framing、2 MiB 响应上限和 JSON 边界；不启动 curl、不读 controller secret。最多接受 512 条活动连接，ID 非空且唯一，字节非负。元数据是 API 提供的证据，不等同于签名认证应用身份。

## 分层与站点匹配

- `MihomoSourceResolver`：存在非空 sniffHost 时以它为准，仅缺失或为空时回退 host；非空但未识别的 sniffHost、两个已识别站点冲突时都退回应用。只匹配精确域名或带点边界的子域，拒绝 URL、端口及恶意后缀，不执行 DNS 请求。
- 固定站点映射为 YouTube（youtube.com、youtu.be、googlevideo.com、ytimg.com）和虎牙直播（huya.com、huya.tv、huyacdn.com）。这是可审查的产品分类表，不是 Mihomo 自带网站识别，也不保证覆盖全部 CDN 或证明正在看视频。
- 有完整可执行路径时复用 `ProcessIdentityResolver` 的外层 app/helper 分组；完整路径 + 固定站点键作为展示身份。缺少路径时不把 basename 或进程名当作身份；未识别站点归到“来源应用未确认（Clash）”。只确认站点时可以显示站点，详情不声称已确认原始应用。
- `MihomoProxyAccumulator`：按连接 ID 的连续增量聚合到来源，保存本次服务运行期间当天按网络类别隔离的内存累计。关闭的连接不再显示活动数，但保留已观测累计。保留最多 128 项／类别，达到上限显示提示，超额明细不强行归给其他来源。
- `AgentMihomoSampling`：与主采集一起启停、取消和等待回收。读取前后检查网络范围，世代校验拒绝停止后返回的旧结果。API 故障重建基线，保留累计；后台约两秒轮询。
- `ApplicationUsageItem`：把 nettop 行和代理来源行放入同一列表，复用 `TrafficSourceRowContent`；代理来源不伪装成可配置额度的普通应用身份。

不保存原始域名、IP、规则、连接流水或网络内容到 SQLite；IPC 仅发送固定站点名称、应用身份和聚合数字。schema 保持 v7，本次来源分时调整不新增表。

## 计量与去重边界

1. 首帧只建立基线；Mihomo 重启、计数回退、连接归属变化、切网、跨日、超过 8 秒间断、单调时钟不连续或 API 故障恢复都不补算未知流量。
2. 单条来源只累计同一连接 ID、同一归属、计数未回退的连续区间；两次 API 读取之间出生或关闭的连接可能漏掉部分字节。无法确认的差额不分配给 YouTube、虎牙或浏览器。
3. 当前日和普通／高成本网络累计隔离；未知网络不分配新增量。暂停和恢复保留本次服务运行累计；后台服务退出后内存明细不保留，重新运行后从零观测。
4. 接口总量、nettop 每日归因、Clash 来源明细各有计量口径。后两者可能重叠，禁止直接相加、相减拼成“直连量”，也不把它们加入接口总量。图表与列表共用来源展示规则；Clash 分钟聚合仅在内存保留，图表合计为可能重叠的展示归因，不表示物理流量或直连量。
5. API 数据不写 daily_usage、不生成新的每日额度或独立预警；现有 nettop 预警和接口总量预警仍各自运作。

## 验证方式

以模拟 JSON、可注入的路径／时钟、临时数据库和原生 SwiftUI 离屏渲染验证。覆盖站点和恶意域名、路径身份、DIRECT 标签、关闭连接后保留累计、网络类别和跨日、采样间断、计数回退、暂停和世代取消、容量限制、列表排序、接口总量不变及不写现有日账本。截图明确标注模拟数据。

上一轮本机 API 只读验证不能替代 YouTube／虎牙真实业务端到端验收。本轮不生成下载、上传、测速或热点实验流量，不承诺所有 VPN/TUN/IPv6 场景，也不追补此前未观测字节。


## 2026-11-06 图表来源统一

MihomoMinuteHistory 将与来源列表相同的连续连接增量先按来源聚合，再按采样结束的绝对分钟、网络类别汇总。首帧、归属变化、切网、超时、计数回退和暂停恢复首帧不产生分钟记录；有效观测零量保留。每来源每次采样计一次有效样本，跨分钟不插值。分钟实体只含固定来源标识／显示名、分钟时间、整数收发字节及有效样本数；不保存连接ID、原始域名或IP。只保留当天本次服务运行数据，暂停保留，重启和日期改变（含回退）清空，每类别上限32768个来源分钟单元。容量限制保留已有单元更新，在图表信息入口提示覆盖缺失；128来源限制仍沿用累计器。

Agent 按请求时段分别查询 SQLite 应用分钟和内存 Clash 分钟，在共同排名前复用列表的精确身份隐藏规则及来源名称，再统一前十与其他。Clash 保留独立来源标识和标签，不伪装成应用额度键。接口总量及现有 nettop 日账本不变；图表合计是混合来源的展示归因，可能重叠，不等于实际物理流量，也不能从中计算直连量。采用现有 v1.19.33 API 解析契约和连续性检查，无新增系统API或依赖。
