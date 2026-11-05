# macOS 发布流程

当前仓库支持可重复的本地开发版发布准备。它会构建 arm64 和 x86_64 两个 DMG，生成 SHA-256 校验文件、更新清单副本和发布说明模板。当前流程不执行 Developer ID 签名、公证、GitHub 上传或自动更新安装。

## 修改版本

版本号和 build 的源文件是 `macos/Configuration/version.env`。使用脚本同步更新它、应用 `Info.plist` 和版本更新清单：

```bash
./scripts/set-version.sh 0.2.0 2 \
  --release-url https://github.com/leon-wenhao/flow-quota/releases/tag/v0.2.0 \
  --download-url https://github.com/leon-wenhao/flow-quota/releases/tag/v0.2.0
```

版本使用三段数字格式；build 必须是递增的正整数。更新清单必须与 `version.env`、`Info.plist` 保持一致，否则发布脚本会停止。

## 准备发布包

```bash
./scripts/release-macos.sh
```

默认输出到：

```text
.artifacts/releases/FlowQuota-0.2.0-build-2/
```

目录包含：

- `FlowQuota-0.2.0-dev-arm64.dmg`
- `FlowQuota-0.2.0-dev-x86_64.dmg`
- `SHA256SUMS`
- `release-manifest.json`
- `update-manifest.json`
- `RELEASE-NOTES.md`

也可以指定新的输出目录，避免覆盖历史发布包：

```bash
./scripts/release-macos.sh --output-dir .artifacts/releases/FlowQuota-0.2.0-build-2
```

## 发布到 GitHub

先检查测试和发布包，再提交版本变更：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path macos --disable-sandbox

git add macos/Configuration/version.env macos/Configuration/Info.plist update-manifest.json
git commit -m "chore: prepare Flow Quota 0.2.0"
git tag -a v0.2.0 -m "Flow Quota 0.2.0"
git push origin main v0.2.0
```

然后在 GitHub 创建 `v0.2.0` Release，上传两个 DMG、`SHA256SUMS` 和 `RELEASE-NOTES.md`。旧版本应用读取远程 `update-manifest.json` 后，会显示新版本并打开 Release 页面。

建议先完成 Release 资产上传，再让远程主分支上的更新清单指向新版本，避免旧版本在资产尚未存在时提前显示可更新。

## 当前限制

- DMG 内应用使用本地 ad-hoc 签名，只适合自用开发验证。
- 没有 Developer ID 签名和 notarization，普通用户可能遇到 Gatekeeper 拦截。
- 发布脚本不创建 GitHub Release，不上传文件，也不修改远程仓库。
- 应用更新检查只提示并打开下载页，不自动下载、校验或替换应用。
- 正式分发前需要单独完成签名、公证、密钥保管和更新包安全验收。
