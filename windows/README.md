# Windows 后续接入入口

本轮仅开发 macOS。本目录是未来 Windows 11 x64 实现入口，不包含 WPF 工程、可执行程序、驱动或下载包。

## 后续模块边界

- TrayApp：C# / WPF 面板与 NotifyIcon，普通用户会话运行。
- ProtectionService：.NET Windows Service，规则、网络状态、SQLite 及恢复。
- TrafficFilterDriver：C/C++ WFP callout；真实计量和已有连接阻断需 Windows x64 验证。
- Installer：离线 EXE/MSI，后续单独安排驱动与发行签名。

共用 `../shared/test-vectors/` 的额度测试资料和产品语义，分别原生实现。
Swift 模型、NSXPCConnection 和 macOS LaunchAgent 不作为 Windows 可复用代码。
建工程前核对当时的官方 .NET、WPF、WFP、WDK、安装和驱动要求；不以 macOS 构建成功代替 Windows 验收。
