# Flow Quota

Local-first per-app traffic monitoring and daily data budgets. 本轮开发 macOS 原生菜单栏应用；Windows 仅保留后续接入入口。

## 当前状态

已建立 SwiftUI 界面、额度规则、SQLite 账本与迁移、NSXPC 本地服务通信、开发构建及测试流程。

**当前开发版本尚不能计量或阻断真实网络流量。** 网络过滤系统扩展的官方部署条件和激活尚未验证，组件未打包进应用。界面显示“保护未就绪”和“未知用量”，额度保存会拒绝未经引擎确认的修改。单元测试、应用能够打开或服务能够运行，均不等于真实保护已交付。

## 本地构建与运行

要求完整 Xcode；本机已验证 Xcode 27.2 / Swift 6.4.2 / macOS SDK 27.2，deployment target 为 macOS 14。无第三方包依赖，使用系统 SQLite。

```sh
./scripts/test-macos.sh
./scripts/build-macos.sh
open ".artifacts/arm64/Flow Quota.app" --args --window
```

默认构建当前机器架构。Intel 编译使用 `./scripts/build-macos.sh --x64`；生成开发 DMG 使用 `./scripts/build-macos.sh --dmg`；发布优化构建使用 `--release`。`--window` 打开供检查的普通窗口；不传参数时通过菜单栏访问。

脚本以项目级 DEVELOPER_DIR 选择 `/Applications/Xcode.app/Contents/Developer`，可覆盖该环境变量，不改动全局 xcode-select。构建缓存、.app、DMG 均在被忽略的 `.artifacts/` 内。

开发包仅做本地 ad-hoc 代码身份标记，用于验证 XPC 对端；未申请或配置发行证书，不提供 NetworkExtension 权限，不等于正式签名／公证。“仍要打开”的应用启动路径与扩展激活分别验证。

首次启动不会自动注册后台服务、登录项、请求通知或安装过滤组件；相关入口由用户明确点击。开发版重编译后，如旧后台进程仍在运行，可在设置选择“修复开发服务”；该入口仅适用于不含过滤扩展的开发包，不放宽对端身份验证。

## 模块结构

| 模块 | 职责 |
| --- | --- |
| macos/Sources/FlowQuotaApp | SwiftUI 菜单栏、额度编辑、设置、通知授权与界面状态 |
| macos/Sources/FlowQuotaCore | 单位、日期、身份、额度判定与原子预算规则 |
| macos/Sources/FlowQuotaStore | SQLite 单写入账本、迁移、通知去重与持久化预留 |
| macos/Sources/FlowQuotaPlatform | 受身份校验的 XPC 客户端、网络成本信号与本地数据权限 |
| macos/Sources/FlowQuotaAgent | 用户会话后台服务、真实状态快照与请求处理 |
| shared/test-vectors | 两端后续共用的额度测试向量及同步检查 |
| windows | 后续 Windows 接入说明，无 Windows 应用或驱动 |

UI 不直接访问数据库。服务默认数据目录为 `~/Library/Application Support/FlowQuota/`，当前用户目录权限 0700，数据库与 sidecar 权限 0600；现有路径校验所有者、文件类型并拒绝符号链接。

## 文档与接续开发

- [项目开发约束](AGENTS.md)：仅适用于本仓库，新窗口和新会话继续遵守。
- [执行计划](docs/execution-plan.md) 与 [实际进度及验证记录](docs/implementation-status.md)。
- [V1 产品设计](docs/flow-quota-v1-设计方案.md)：双平台作为后续目标，本轮仅 Mac。
- [额度规则](docs/quota-rules.md)、[数据库设计](docs/database-design.md)、[原生界面](docs/ui-implementation.md)。
- [官方依据与工具链](docs/official-references.md)、[真实过滤阻塞记录](docs/tasks/002-real-filter.md)。
- [Windows 后续接入](windows/README.md)。

恢复任务时先读取 AGENTS.md、实际进度记录及对应任务卡，不根据聊天记录或原始设计推断功能已完成。
