# macOS 单仓库发布

源码与安装包统一发布到公开仓库 `leon-wenhao/flow-quota`，采用 MIT 许可证。DMG 是 Release 附件，不加入 Git 历史。方案见 [单仓库方案](public-distribution-plan.md)。

## 日常发布

先完成并审查源码，再设置版本。对外标题只显示三段版本号，tag 例如 `v0.1.4`，不带 build 后缀；每次发布版本号和内部构建号都必须递增。

0.1.7 发布后，下一次发布可使用：

```bash
./scripts/set-version.sh 0.1.8 29
git add <本次需要发布的文件>
git commit -m "release: prepare 0.1.8"
git push origin main
./scripts/release-macos.sh --publish --activate-manifest
```

日常修改建议在 `codex/功能名` 分支完成并合入 `main`；发布从干净、已经推送的源码执行。脚本不会提交工作区修改、公开仓库或删除仓库；这些是本次迁移的一次性操作。先仅本地打包：

```bash
./scripts/release-macos.sh
```

输出默认位于 `.artifacts/releases/FlowQuota-版本-build-构建号/`；已存在的目录不能覆盖，可指定 `--output-dir`。

## 发布与更新顺序

1. 验证 origin 与目标都是 `leon-wenhao/flow-quota`，仓库公开、可用且默认分支为 main；工作区干净。
2. 构建 Apple silicon 与 Intel 的 release DMG，检查 app/Agent 签名、架构、版本和最小系统版本；保存实际源码提交。
3. 使用明确的八文件白名单：两个 DMG、`appcast-arm64.xml`、`appcast-x86_64.xml`、`SHA256SUMS`、`release-manifest.json`、`update-manifest.json`、`RELEASE-NOTES.md`。更新源和 DMG 使用 Ed25519 签名，并以提交的公钥进行独立验证。拒绝额外文件、目录和符号链接。
4. 验证 bundle 的 sourceCommit 属于远端 main；tag 必须准确指向该提交。建立草稿，按白名单上传；核对 GitHub 返回的名称、上传状态、大小和 SHA-256 后发布，暂不标记 latest。
5. `--activate-manifest` 再次验证正式附件，拒绝版本回退，并读取上一版清单确认内部构建号严格递增后标记 latest。新客户端按架构使用 `https://github.com/leon-wenhao/flow-quota/releases/latest/download/appcast-arm64.xml` 或 `appcast-x86_64.xml`。0.1.5 及之前客户端仍读取：
   `https://github.com/leon-wenhao/flow-quota/releases/latest/download/update-manifest.json`。

根目录 `update-manifest.json` 只是构建输入，设置下一个版本不影响在线更新。更新入口不依赖 main 新增提交，也不使用跨仓库同步。所有版本发布操作应串行执行，避免同时改变 latest。

## 中断恢复

保留原 bundle，重试以下命令，不重新构建或覆盖正式附件：

```bash
python3 scripts/publish_macos.py   --bundle .artifacts/releases/FlowQuota-0.1.7-build-28   --activate-manifest
```

草稿只补传缺失项，已上传项必须摘要相同；正式版仅核验，不使用 `--clobber`。若正式版已发布但 latest 激活失败，重复命令只会核对并恢复激活。源码或附件有变动时递增版本号和内部构建号，不改写原 tag。

## 安装与构建限制

更新只由用户点击“检查更新”触发。0.1.6 起使用 Sparkle 标准界面，经用户确认后按架构下载、校验并完成替换和重启；首次安装及旧版仍可通过 DMG 拖拽安装。没有后台自动检查、静默下载或网络阻断。

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
