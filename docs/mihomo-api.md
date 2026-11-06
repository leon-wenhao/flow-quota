# Clash 来源识别与完整用量拆分

更新：2026-11-06，Asia/Shanghai。适用当前 macOS 提醒版。只读连接信息，不修改 Clash/Mihomo 配置，不负责阻断。

## 产品语义

主列表将已确认内核用量拆分为 `YouTube（Clash）`、`虎牙直播（Clash）` 与 `其他未识别（Clash）`，全部保留父项字节，父项不再重复列出。站点/应用子项不进入每日额度编辑；内核整体提醒与原始记录在用量详情。

“（Clash）”表示经 Mihomo 处理，包含 DIRECT 规则，不等于必经代理节点。各来源以父项为边界按分钟核对，方向冲突时该分钟全量未识别。物理接口保持独立，普通应用不声称已剔除代理成为直连量。方案和边界见 `clash-usage-breakdown.md`、`traffic-accounting.md`。

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
- `MihomoProxyAccumulator`：连接连续性、128 项容量和原始本次运行 API 诊断；每帧输出已验证来源增量及单调时钟区间。站点按固定站点 ID 合并不同调用进程，未知进程名不升级为应用身份。
- `AgentMihomoSampling`：约两秒轮询，写入 Store 事务成功后推进累计器；失败重建基线，错误可见。世代和网络范围拒绝过期响应，接口/进程独立继续采集。
- `ClashMinutePersistence`：schema v9 的当前日、类别、来源分钟聚合；最多 128 来源及 32768 单元，批次超容量全部回滚，跨日/回退统一清理。SQLite 不存域名、IP、连接 ID、原始规则或网络内容。
- `ClashMinuteBreakdown` / `ClashUsageBreakdown`：按原始分钟先核对上下行，再合并图表桶及每日；已识别超出任一父项方向时整分钟未识别，不缩放。日合计中缺分钟证据的旧数据也进入未识别。
- `ApplicationUsageItem`：常规应用与已拆分来源共用列表、排名与菜单；所有来源保留，不重复加入内核父项。原始计数在计量详情可查。

## 计量与去重边界

1. 首帧只建立基线；Mihomo 重启、计数回退、连接归属变化、切网、跨日、超过 8 秒间断、单调时钟不连续或 API 故障恢复都不补算未知流量。
2. 单条来源只累计同一连接 ID、同一归属、计数未回退的连续区间；两次 API 读取之间出生或关闭的连接可能漏掉部分字节。无法确认的差额不分配给 YouTube、虎牙或浏览器。
3. 当前日和网络类别隔离；未知网络不分配新增量。暂停和服务重启保留已提交的当天来源分钟，恢复首帧仍重建基线，不导入 session 累计。
4. 父项取 nettop；API 只提供可核对的来源。未捕获连接、不可识别连接与计量差异保留为其他未识别。不从来源反造接口总量，也不能由浏览器和代理相减得到直连量。
5. API 不写 daily_usage、不生成子项每日额度或独立预警。接口和内核预警保持原始阈值判断；新预警可保存冻结的来源子项，旧事件不回填。

## 验证方式

以模拟 JSON、可注入的路径／时钟、临时数据库和原生 SwiftUI 离屏渲染验证。覆盖站点和恶意域名、路径身份、DIRECT 标签、关闭连接后保留累计、网络类别和跨日、采样间断、计数回退、暂停和世代取消、容量限制、列表排序、接口总量不变及不写现有日账本。截图明确标注模拟数据。

上一轮本机 API 只读验证不能替代 YouTube／虎牙真实业务端到端验收。本轮不生成下载、上传、测速或热点实验流量，不承诺所有 VPN/TUN/IPv6 场景，也不追补此前未观测字节。
