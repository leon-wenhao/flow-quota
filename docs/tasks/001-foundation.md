# 001 工程、约束与本地构建

状态：已完成本轮工程与开发构建验证。

目标：原生 macOS 工程可独立构建，约束落盘，Windows 仅预留入口。
范围：Swift Package 多 target、开发 .app 打包脚本、工具链与运行说明。
依赖：完整 Xcode；不需要 Windows 环境。
验收：测试通过；arm64 .app 构建；x86_64 编译；签名身份与系统条件如实记录。
证据：统一记入 ../implementation-status.md。
