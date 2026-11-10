# GitHub / Gitee 双源更新与发布

2026-11-10 更新。借鉴狐文的“仓库固定文件提供更新元数据、Release 提供安装包”方式；Flow Quota 继续使用 Sparkle 2.10.1 原生更新和 Ed25519 签名。

## 客户端入口

每次检查先使用 GitHub latest Release 的架构 appcast。检查失败后只回退一次 Gitee；正常返回无更新不切源。Gitee 固定入口为 `Leon-wh/flow-quota` 的 `codex/update-feeds` 分支：

- `updates/appcast-arm64.xml`
- `updates/appcast-x86_64.xml`

`GiteeUpdateFeed` 仅构造对应架构的 HTTPS 地址，Sparkle 下载并验证签名后解析。客户端不查询 Gitee Release 列表、标题、正文、ready 标记或 `/releases/latest`。平台替换发布说明正文不会直接改变更新发现逻辑；如果平台阻断原始文件或安装包下载，更新仍会失败并显示错误。

手动和自动检查共用源选择。自动只查询并提示，不弹窗、下载或安装；手动成功探测后在同源打开 Sparkle 标准界面。关闭自动检查阻止后续备用探测，手动不受影响。签名、公钥、包预验证及停止采集后安装的交接流程保持一致。

## 发布和激活

源码 main、版本、构建号及 tag 在两端一致；tag 指向构建源码。双架构安装包只构建一次，镜像保持同一字节及签名。Gitee appcast 将 enclosure 改为对应 Gitee 安装包地址后单独签名；其余公共元数据保留原始 bundle 的审计数据。八项附件白名单不变，不提交 DMG、凭据或本机数据到 Git。

`scripts/publish_dual.py` 顺序执行：

1. 验证干净源码及 bundle，双端推送源码和准确的 tag。
2. 发布 GitHub 非 latest Release，在 Gitee 预览版中补齐缺失附件。
3. 核对 Gitee 源码 tag／目标提交及八项匿名附件；逐项校验大小和 SHA-256，验证 feed 与安装包签名。发布说明以摘要一致的 `RELEASE-NOTES.md` 附件为准，正文仅用于平台展示。
4. 预检 GitHub latest 和 Gitee 固定清单的版本／构建号递增约束。
5. 将 Gitee Release 转为正式版，公开回读确认 tag、源码提交及正式状态。
6. 在临时 Git 仓库提交两份当前清单和两份 `updates/versions/v版本/` 不可变清单，一次非强制推送到 `codex/update-feeds`；不操作调用者的索引、main 或 tag。
7. 匿名回读四份原始文件，要求字节完全一致，然后激活 GitHub latest。

独立分支只用于发布签名 XML，不维护第二套应用实现。版本号和构建号必须同时递增；同版本只允许完全相同内容重试，不能改写历史清单。普通 Git 推送拒绝并发提交冲突。缺失／超大／非法签名清单、架构不一致、外部安装包地址、回退及同版本变更均停止发布。

两端没有原子事务。`-publication.json` 分别记录 Gitee Release 正式发布、固定清单匿名核验通过和 GitHub latest 激活。若推送后回读失败，清单可能已经生效；保留同一 bundle 重试，GitHub latest 暂不推进。每次重试重新核对远端真实状态，不以本机记录代替验证。命令和凭据配置见 [macOS 发布流程](release-macos.md)。

## 官方依据与验证范围

- Gitee API 5.4.93 的 Release、附件列表和下载接口；附件未声明 SHA-256，必须自行匿名回读并计算。官方入口为 Gitee API v5 swagger，本机核对副本在忽略目录 `.artifacts/gitee-api-doc.json`。
- Sparkle 固定依赖 2.10.1：`SPUUpdaterDelegate.h` 的 `feedURLStringForUpdater:` 支持选择 feed；`SUAppcastDriver.m` 在解析前校验签名；`sign_update/main.swift` 按 `.xml` 后缀签署 appcast。Gitee 临时签名文件保留 `.xml` 后缀，并在提升为最终文件前验证签名与原始内容。
- 离线测试使用临时 Git 裸仓库及模拟 API，覆盖首次激活、幂等重试、版本递增、回退拒绝、并发冲突、正文被替换和匿名回读失败；不以模拟结果冒充线上可用。

## 线上状态（2026-11-10）

0.1.13（构建 34）已在 GitHub 和 Gitee 正式发布；两端源码 tag `v0.1.13` 均指向 `c0d9c3c836621cd977eaedf2ea6fdc2d1bdb23a0`。两个 DMG 只构建一次，两端八项附件通过大小／摘要及签名核验。

Gitee `codex/update-feeds` 分支已首次推送，两份当前清单及两份版本清单均完成匿名字节回读；GitHub latest 随后激活为 0.1.13。Gitee 公共标题／正文仍被平台审核替换，附件和固定 raw 地址可以匿名取得；没有修改已发布的 0.1.12。

Gitee Release API 凭据尚未配置；本次通过用户已登录的 Chrome 上传和转正式，随后调用相同脚本完成公开核验、签名清单推送和激活。未创建新凭据。真实客户端跨版本安装、Intel 真机及不同国内网络可达性尚未验收。

不为验收制造热点下载、上传或测速流量。固定文件可访问、附件一致、国内匿名连接及实际安全安装须分别记录；编译和离线测试仅证明对应代码路径。
