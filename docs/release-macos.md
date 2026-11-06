# macOS 双仓库发布流程

源码仓库 `leon-wenhao/flow-quota` 保持私有。下载、Issues、Release 和客户端清单使用独立公开仓库 `leon-wenhao/flow-quota-releases`。完整边界见 [分发方案](public-distribution-plan.md)。当前包只有 ad-hoc 开发签名，未 Developer ID 签名或 Apple 公证。

## 初始化与更新公开资料

需要官方 GitHub CLI、账号仓库写权限；先执行 `gh auth status`。凭据不写入代码或命令参数。首次建立空公开仓库：

```bash
gh repo create leon-wenhao/flow-quota-releases --public \
  --description 'Flow Quota macOS 安装包、使用说明与反馈（闭源分发）'
```

同步公开资料：

```bash
/usr/bin/python3 -B scripts/public_repository.py
```

脚本只允许 `distribution/public/` 中的 README、INSTALL、DISTRIBUTION 和 `assets/logo.png`。它检查源仓库私有、目标仓库公开，审计公开分支与 tag 的所有祖先文件，然后通过官方 Contents／Git Trees／Commits／Refs API 提交独立历史。公开提交使用 GitHub noreply 邮箱。

首次仅用 README 初始化空仓库，再以 Git tree 原子提交其余资料；以 `force: false` 更新 main。后续同步只提交有变化的白名单文件，不复制源码历史。公开历史发现额外文件或符号链接时停止，不用删除文件假装撤销泄漏。

本机原生 Git 到 github.com:443 曾出现 HTTP/2 传输失败、HTTP/1.1 连接超时；API 端点正常，因此公开发布使用官方 REST API，不依赖本地公开 clone。GitHub 自动生成的 Source code 压缩包仅包含公开资料，不含应用源代码。

## 版本与本地验证

`version.env` 是版本源，build 递增。对外 Release 标题、发布说明标题及应用内版本仅展示三段版本号（如 `Flow Quota 0.1.1`），不附加括号中的 build；内部构建号、清单及唯一 tag 保留用于更新排序和追踪。tag 使用 `v版本-build.构建号`，不覆盖正式版本。例如：

```bash
./scripts/set-version.sh 0.1.0 19 \
  --release-url https://github.com/leon-wenhao/flow-quota-releases/releases/tag/v0.1.0-build.19
/usr/bin/python3 -B -m unittest discover -s scripts/tests -v
./scripts/test-macos.sh
./scripts/release-macos.sh
```

默认输出为 `.artifacts/releases/FlowQuota-0.1.0-build-19/`；可用 `--output-dir` 指定新的目录，已有目录不能覆盖。构建脚本去除 debug／local 符号后签名，`verify_macos_app.py` 检查明确的 app 文件清单、主程序与 Agent 架构、macOS 14 deployment target、本机路径及签名。临时 DMG staging 在退出时清理。Intel 交叉编译通过不等于 Intel 真机运行验收。

禁止为验收生成热点测速或上传／下载实验流量。使用本地包与模拟响应验证，不下载公开 DMG 做对照实验。

## 发布与激活

先审查并提交实际打包的私有源码和相关文件，并同步私有 origin。源码提交和公开资料提交分别处理。发布器不替用户自动提交源码。已有本地 bundle 可以直接发布：

```bash
/usr/bin/python3 -B scripts/publish_macos.py \
  --bundle .artifacts/releases/FlowQuota-0.1.0-build-19 \
  --activate-manifest
```

也可以新构建与发布一起执行：

```bash
./scripts/release-macos.sh --publish --activate-manifest
```

流程：

1. 检查仓库隔离、私有源码 clean 状态与公开历史白名单，重新核算本地包大小和 SHA-256。
2. 仅用公开 main 的提交建立 tag，创建 Release 草稿。
3. 显式上传两个架构 DMG、SHA256SUMS、release-manifest.json、update-manifest.json、RELEASE-NOTES.md，拒绝目录额外文件及符号链接。
4. 核对 GitHub 返回的每个资产名称、上传状态、size、SHA-256 digest，全部符合才发布 Release。
5. 再核对正式 Release，最后只向公开 main 提交更新清单。更新 refs 不强推；同版本不同清单、版本回退或并发 main 变化均停止。

源码 SHA 不进入公开 tag 或附件；根清单只是构建输入，真正供客户端使用的激活清单在公开仓库。

## 失败与恢复

- 草稿创建后列表尚未返回：先只读核实草稿，确认存在后重复同一命令；未查到草稿时不激活清单。
- 上传中断：保留草稿和本地 bundle，重复同一 `publish_macos.py` 命令。只补传缺失项，已有项必须摘要一致，不用 `--clobber`。
- 附件不符或出现额外文件：停止，查明原因后人工修复草稿。不要激活清单或覆盖正式版本。
- Release 成功、清单提交失败：重复同一命令，验证正式资产后再提交清单；不重传正式附件。
- 重新构建发布：提高 build，使用新 tag。不要修改已正式发布的二进制。
- GitHub 缺少写权限：保留可审查的本地包，恢复权限后继续，不能把源码仓库改公开解决。

## 客户端与当前限制

默认地址为公开仓库 `main/update-manifest.json`。用户主动检查，按当前架构下载，验证 size/SHA-256 后打开 DMG，由用户手动拖拽替换。旧版本需要手动安装一次包含新地址的版本。没有静默替换、后台自动更新或网络阻断。

安装说明明确 ad-hoc、未公证；使用 Apple 正常的单应用打开入口，不提供关闭系统安全机制的命令。发布仓库隔离保护源码和历史，不能保证二进制无法被逆向。

官方 API、CLI 与 Apple 依据见 `docs/official-references.md`；实际结果见 `docs/public-distribution-verification.md`。
