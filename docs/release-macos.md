# macOS 双平台发布

GitHub `leon-wenhao/flow-quota` 与 Gitee `Leon-wh/flow-quota` 维护同一份源码、版本和 tag。DMG 仅作为 Release 附件，构建一次、签名一次，再将相同字节发布到两端。0.1.13 已双端发布并完成八项附件核验，Gitee 固定签名清单与 GitHub latest 已激活。Gitee Release API 凭据仍待配置，本次使用登录网页上传；真实客户端跨版本安装及不同国内网络可达性尚未验收。详细状态见 [双平台方案](gitee-distribution-plan.md)。

## 日常提交

在 `codex/功能名` 分支开发并审查，合入本地 main 后执行：

```bash
python3 scripts/push_sources.py
```

脚本使用固定的 GitHub HTTPS 与 Gitee SSH 地址，分别推送 main 并核对远端提交；不依赖 `.git/config` 的双 push URL，不强推或镜像删除。任一端失败会显示已完成端，解决连接或授权后重跑同一命令。新机器需先完成 `gh auth login` 和 Gitee SSH 密钥授权。

## 发布前配置

GitHub 使用 `gh` 已登录的发布权限；Gitee Release API 与 SSH 是不同授权。使用可读取授权用户资料、发布目标仓库 Release 的 Gitee 令牌，可通过环境变量 `GITEE_TOKEN` 提供，也可在本机钥匙串保存。以下命令提示安全输入，不把令牌写入命令参数：

```bash
security add-generic-password -a flow-quota -s flow-quota-gitee -w
```

不要将令牌发送到聊天、写入源码或版本附件。发布脚本在任何远端变更前检查两端 API 凭据及公开仓库；实际写入权限由各平台在发布操作时确认，拒绝后记录部分状态并停止。Sparkle 私钥继续使用原有钥匙串账户 `local.flowquota.app`。

## 正式发布

每次同时递增三段版本号和内部构建号。本次配置为 0.1.13 / 34；发布前核对两端最新版本，不能复用已发布版本。

```bash
./scripts/set-version.sh 0.1.13 34
git add <已审查的本次文件>
git commit -m "release: prepare 0.1.13"
python3 scripts/push_sources.py
./scripts/release-macos.sh --publish --activate-manifest
```

不发布，仅本地构建：`./scripts/release-macos.sh`。默认输出为 `.artifacts/releases/FlowQuota-版本-build-构建号/`，不能覆盖已有目录。正式发布从干净工作区执行，脚本不替用户提交改动。

发布流程串行执行，不同时启动多个版本：

1. 验证两端公开仓库与可用 API 凭据；构建两个架构的 DMG，并检查版本、架构、最低系统版本、签名和内容白名单。
2. 验证 bundle 和 sourceCommit，在两端推送同一 main 与精确指向源码的 `v版本` tag。已有 tag 不同则停止。
3. GitHub 先建 draft，按八文件白名单上传，核对服务器大小和 SHA-256 后发布，但不设为 latest。
4. Gitee 先建 prerelease，上传同一 DMG 与公共说明／清单。根据实际附件 URL 生成 Gitee 专用架构 appcast：沿用原包 Ed25519 签名，独立签署 feed。白名单仍为两个 DMG、两个 appcast、SHA256SUMS、update-manifest.json、release-manifest.json、RELEASE-NOTES.md。
5. 不带令牌读取 Gitee 版本及附件，流式计算实际附件 SHA-256，与本地逐项比对，并检查 DMG 下载文件名能被 Sparkle 识别。不能只依赖名称／大小；拒绝 GitHub 下载地址和不受支持的重定向。此为正式发布审计，遵守不在热点下做实验性下载的限制；0.1.12 已执行实际附件匿名回读；本轮新发布流程使用离线模拟验证，0.1.13 固定清单已通过真实匿名回读。
6. `--activate-manifest` 先检查 GitHub 与 Gitee 的版本／构建号单调递增，再将 Gitee 置为正式版，再通过 `gitee_feeds.py` 将两个已签名 appcast 一次非强制推送到 `codex/update-feeds` 分支，匿名回读完全一致后，最后将 GitHub 设为 latest。客户端直接读取固定清单，不依赖 Release 正文或 ready 标记。

客户端不查询 Gitee Release 列表或 `/releases/latest`。固定分支只发布签名 XML：`updates/appcast-{arm64,x86_64}.xml` 为当前入口，`updates/versions/v版本/` 保留不可变清单。版本号和构建号必须同时递增；相同版本只允许字节完全一致的重试。非强制推送拒绝并发冲突，不修改 main、源码 tag 或当前工作区。两端不是原子事务；不回滚、不覆写已发布包，按记录继续即可。

根目录 `update-manifest.json` 只是构建输入。Gitee 公共 JSON 清单保留 GitHub bundle 的原始审计数据，客户端只使用 Gitee 独立签名的 appcast 及其 Gitee enclosure；不会沿公共清单里的 GitHub URL 下载。

## 中断恢复

保留原 bundle 及同级的 `-gitee` 签名 feed 目录。重跑，不重新构建：

```bash
python3 scripts/publish_dual.py \
  --bundle .artifacts/releases/FlowQuota-0.1.13-build-34 \
  --activate-manifest
```

仅上传待审查附件时省略 `--activate-manifest`。`publish_macos.py` 的命令行入口也转入双端发布，避免旧命令意外只发布 GitHub；其内部 GitHub 适配函数供双端脚本调用。

同级 `-publication.json` 记录当前执行已确认的同步、发布、核验和激活步骤，不含凭据。它是排障记录，重试仍读取远端真实状态，不信任记录代替验证。草稿／预览版只补传缺失项；已有附件必须摘要一致，正式版缺附件或内容不同直接报错，不能原地补包。若 PATCH 成功但响应丢失，下次通过公开列表核对恢复；记录分别区分 `giteeFormal`（Release 已正式发布）、`giteeActivated`（清单已推送且匿名回读通过）及 `githubActivated`。若推送后匿名回读失败，固定文件可能已经生效，GitHub latest 保持原状；使用同一 bundle 重试回读，不另建版本。若 GitHub latest 激活失败，保留已完成的 Gitee 激活并重试。

## 安装与构建限制

2026-11-09 起，默认自动查询新版本，可在设置关闭；检查不受网络类别或采集启停限制，只在界面提示。用户点击“检查更新”后使用 Sparkle 标准界面，经确认按架构下载、校验并完成替换和重启；首次安装及旧版仍可通过 DMG 拖拽安装。不自动下载或安装，不提供网络阻断。

DMG 固定图标视图：Flow Quota 在左、Applications 在右、中间箭头、底部安装提示及说明文件。构建布局需要登录图形会话和 Finder 自动化授权，失败时明确停止；用户打开成品无需此授权。同版本卷已挂载时先手动推出。可单独打包：

```bash
./scripts/package-macos-dmg.sh "$PWD/.artifacts/arm64/Flow Quota.app"   "$PWD/.artifacts/FlowQuota-installer-arm64.dmg"
```

当前仅 ad-hoc 签名，未 Developer ID 签名或 Apple 公证。按 [安装说明](../INSTALL.md) 使用系统“隐私与安全性 → 仍要打开”入口。构建通过不代表 macOS 14 或 Intel 真机运行验收；不使用热点流量做实验性验证。

本次迁移没有旧版使用者，不保留旧入口；历史 0.1.2 仅归档安装包，新版本使用本仓库更新地址。执行结果见 [验证记录](public-distribution-verification.md)，官方依据见 [本次资料](single-repository-official-references.md)。

## Sparkle 签名密钥与工具

当前开发机已生成签名密钥，保存在 macOS 登录钥匙串账户 `local.flowquota.app`；源码只包含 Info.plist 的 `SUPublicEDKey`。日常发布直接执行原命令，脚本先检查密钥和公钥匹配，再构建和签名。无需 Apple 开发者账号。

```bash
# 可独立检查工具下载、校验和钥匙串身份，不会发布
./scripts/sparkle-tools.sh
```

工具固定为官方 Sparkle 2.10.1，发行包 SHA-256 写在脚本中，缓存于 `.artifacts/sparkle-tools/`。SwiftPM 精确锁定相同框架版本及校验值，构建保留第三方嵌套签名并逐文件审计，外层应用与自有 Agent 仍使用 ad-hoc 签名。升级 Sparkle 时须一起更新版本、工具摘要、`sparkle-files.json` 文件清单及验收结果。

**保管好原签名密钥。** 更换发布机器时必须从原钥匙串安全导出并导入，不能随便生成新密钥替代。若需要备份，手动执行官方工具的导出操作，将目标放在仓库之外的加密存储中：

```bash
.artifacts/sparkle-tools/bin/generate_keys --account local.flowquota.app -x /安全的仓库外路径/flow-quota-update-key
# 在新发布机安装工具后导入同一个私钥
.artifacts/sparkle-tools/bin/generate_keys --account local.flowquota.app -f /安全的仓库外路径/flow-quota-update-key
./scripts/sparkle-tools.sh
```

请勿上传私钥、打印私钥内容或将其放入 Release 输出目录。未加入 Apple Developer ID 签名的应用丢失 Ed25519 私钥后，无法为已安装客户端安全签发后续自动替换更新，须由用户重新手动安装。框架签名与公开密钥验证不替代 Gatekeeper 或 Apple 公证。

新客户端首次发布时，已安装的 0.1.5 仍需通过原 DMG 流程升级一次，之后使用应用内更新。真实跨版本替换与系统提示仍须在实际安装环境验收；编译、签名检查及模拟服务测试不能代替该项。

## 构建暂存与编辑器索引

DMG 的 `Applications` 符号链接只用于安装入口。打包工作目录使用系统临时目录
`${TMPDIR:-/tmp}/flow-quota-dmg.*`，不放入源码工作区；正常退出、错误退出及
INT/TERM 中断均触发清理。若临时镜像无法卸载，脚本报错并保留路径，先卸载再清理；
SIGKILL 或断电无法执行退出清理，恢复后检查该临时路径。

`.vscode/settings.json` 在本工作区关闭 C/C++ IntelliSense，将备用浏览范围收窄至
`macos/Sources`，并从文件视图、监视、搜索及 C/C++ 索引中排除构建目录。
搜索不跟随符号链接。不要仅依赖 `.gitignore` 控制编辑器索引。
2026-11-06 核对本机 C/C++ 扩展 1.35.6 的官方 `package.json` 设置定义；参考
[官方 C/C++ 配置说明](https://code.visualstudio.com/docs/cpp/customize-cpp-settings)与
[官方搜索说明](https://code.visualstudio.com/docs/editing/codebasics)。

旧版 `.artifacts/dmg-stage.*` 可能残留指向 `/Applications` 的链接；确认没有打包任务或
挂载镜像使用后可删除这些暂存目录。异常索引须先应用排除设置、停止持有它的索引进程，
再删除对应工作区的缓存；不要删除其他工作区缓存或手动处理系统交换文件。
