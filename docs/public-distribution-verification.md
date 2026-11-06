# 公开分发验证记录

日期：2026-11-06。环境：macOS 27.2 / Apple Silicon、Xcode 27.2、Swift 6.4.2、最低 macOS 14；系统 Python 3.9.6、GitHub CLI 2.103.3。

## 本地结果

- `scripts/test-macos.sh` 完整回归通过：Swift Testing 341 项，XCTest 37 项，包含公开更新地址、更新包校验、数据迁移与当天清理相关测试。
- `python3 -B -m unittest discover -s scripts/tests -v`：52 项离线测试通过，覆盖发布 bundle 白名单、大小及摘要、跨仓库拒绝、公开历史审计、原子 refs 更新、草稿恢复、失败不激活、版本回退与并发更新。
- shell 语法、Python 模块加载及 `git diff --check` 通过。
- 版本 `0.1.0`，build `19`；两个架构优化构建成功。签名前执行 Apple `strip -S -x`，包内不附带 dSYM。
- 两个 DMG 的 UDIF checksum 校验通过；只读挂载后，顶层内容为 app、Applications 链接和安装说明（仅允许系统卷元数据），主程序与本地构建二进制逐字节一致。
- 主程序、Agent 和 app 的严格 codesign 校验通过；arm64 / x86_64 架构分别匹配，Mach-O minos 14.0。app 文件白名单通过，二进制无本机 `/Users/` 路径，旧的私有更新清单地址未残留。
- 临时 DMG staging 已在构建结束清理，校验挂载已推出。未安装或启动公开包，未操作生产数据库，未进行热点下载／上传／测速实验。

本次输出目录：`.artifacts/releases/FlowQuota-0.1.0-build-19-public/`。发布附件严格为两个 DMG、SHA256SUMS、update-manifest.json、release-manifest.json、RELEASE-NOTES.md。

## GitHub 与传输

- 已确认源码仓库 `leon-wenhao/flow-quota` 为 PRIVATE，当前账号具有 ADMIN 权限。
- 已创建 PUBLIC 仓库 `leon-wenhao/flow-quota-releases`；公开资料通过官方 API 提交，初始历史仅公开文档和品牌图标，提交者使用 noreply 邮箱。
- 本机 Git HTTPS 原生端点先发生 HTTP/2 framing 错误，HTTP/1.1 又连接超时。GitHub REST API 正常；公开资料与清单使用已测试的 API 发布流程，未修改全局代理、DNS 或源码仓库可见性。
- 私有源码同步如需使用 Git Database API，必须固定私有目标，按本地准确 tree/commit 创建对象，服务端 SHA 全部一致后才能以 `force: false` 更新 main；任何不一致都停止，不能悄悄创建不同的源码版本。

## 线上发布结果

- 版本：`0.1.0 (build 19)`，tag `v0.1.0-build.19`，Release ID `436027497`。
- 正式发布于 2026-11-06 10:23:42（Asia/Shanghai），`draft=false`，共六个附件；名称、上传状态、大小及 GitHub SHA-256 digest 全部与本地一致。
- 发布页：<https://github.com/leon-wenhao/flow-quota-releases/releases/tag/v0.1.0-build.19>。
- Apple Silicon DMG：2,355,200 bytes，SHA-256 `c0fc2dbfb331d85add702bf46ea4002db3e452f2c32314c6201d2c82af7c89f1`。
- Intel DMG：2,468,864 bytes，SHA-256 `ebfe89d4fccb8022cfaa00e2f56464e8972c35757456052ce3d32ec897e2059c`。
- 公开 main 已在正式发布后激活 `update-manifest.json`；通过官方 Contents API 匿名读取，与本地 1,076 bytes 的清单逐字节一致。公开历史仅包含三份文档、图标和更新清单。
- 打包对应私有源码提交 `070379b` 已同步，GitHub 与本地 commit/tree SHA 一致；未将其作为公开 tag 或附件内容。
- 实际经历了草稿创建后列表短暂未返回的情况：首次发布按设计停止且未激活清单，确认唯一草稿后重复同一命令，从同一 bundle 恢复成功，未重建／覆写正式附件。

客户端默认地址 `raw.githubusercontent.com/.../main/update-manifest.json` 的匿名直连请求在本机 25 秒超时；本轮**未通过当前网络下客户端 Raw 入口连通性验收**。Contents API 的匿名读取成功只证明公开文件存在且内容正确，不等于 Raw 域名或另一台设备的检查／下载成功。恢复对该域名的网络访问后，可只检查小清单进行复验；不得用热点下载 DMG 做实验。

## 验收边界

当前应用为 ad-hoc 开发签名，未 Developer ID 签名、未 Apple 公证。公开说明已明确；未验收另一台全新 Mac 的 Gatekeeper 打开流程或通知授权流程。Intel 包完成交叉编译和静态检查，尚未 Intel 真机运行验收。未进行运营商误差对照。旧版需要手动安装一次包含公开更新地址的版本。


## 0.1.1 重新打包发布（2026-11-06）

- 对外名称为 `Flow Quota 0.1.1`；发布标题、说明标题和应用内当前版本不再显示括号中的 build。内部构建号为 22，唯一 tag 为 `v0.1.1-build.22`，保留更新排序与追踪语义。
- 打包源码提交 `cd7ef1f18e47476705b4ebdd98b61f01f7c5f023` 已推送私有 main，远端与本地一致。包含最新预警记录表格、空状态、悬停描边移除及版本展示调整。
- 341 项 Swift Testing、37 项 XCTest 和 52 项发布离线测试通过；双架构 release 构建、App 文件白名单、架构、最低系统版本及严格签名检查通过。两份 DMG checksum 验证、只读挂载签名检查与主程序／Agent 二进制一致性检查通过，挂载已推出。
- 正式发布于 2026-11-06 10:41:02（Asia/Shanghai），Release ID `436039000`，六个附件的大小、状态与 SHA-256 全部一致，之后激活公开清单；再次通过 Contents API 核对，清单与本地逐字节一致。
- Apple Silicon DMG：2,365,952 bytes，SHA-256 `948fff81b6692bef105a4b28f08aa09e223b9973320c04d77e930cccd42cce29`。
- Intel DMG：2,477,568 bytes，SHA-256 `f62e724398e2a5442ccb935466d8145f2decd85874deb110872b766c777eacd0`。
- 发布页：<https://github.com/leon-wenhao/flow-quota-releases/releases/tag/v0.1.1-build.22>。本地 bundle：`.artifacts/releases/FlowQuota-0.1.1-build-22-release/`；验证证据：`.artifacts/release-0.1.1-*.log` 及 `.artifacts/release-0.1.1-online-verification.json`。
- Raw 更新清单入口在当前网络再次出现 20 秒超时、0 bytes；公开发布与 API 清单验证成功不代表当前网络中的客户端检查更新已通过。该连通性限制仍未解除，未为验收下载公开 DMG。
- 本轮仅打包发布，不替换本机正在采集的 App、不操作生产数据库；没有生成测试上传、下载或测速流量。ad-hoc、未公证及未完成 Intel 真机运行的边界保持不变。
