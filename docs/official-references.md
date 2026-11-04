# 官方依据与工具链

验证日期：2026-11-04。本地 Xcode 27.2（27B52）、Swift 6.4.2、macOS SDK 27.2；deployment target macOS 14。脚本通过 DEVELOPER_DIR 选择 Xcode，不修改全局 xcode-select。

## Apple

- [TN3134 Network Extension provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)：内容过滤器部署类型及分发条件。
- [Installing System Extensions and Drivers](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers)：激活期间校验代码身份和 entitlement。应用打开与扩展激活分别验证。
- [NSXPCConnection](https://developer.apple.com/documentation/foundation/nsxpcconnection)：接口、生命周期、错误与失效处理。SDK `NSXPCConnection.h` 明确 `setCodeSigningRequirement` 自 macOS 13 可用；双方在 resume 前设置需求，不通过可猜测的名字信任调用者。
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)：LaunchAgent plist 放在 app 的 Contents/Library/LaunchAgents，使用 BundleProgram 解析应用内路径。
- [NWPath.isExpensive](https://developer.apple.com/documentation/network/nwpath/isexpensive)：仅作为成本信号；无法确认热点时显示未知并允许手动标记。
- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)：菜单栏 window 样式与原生生命周期。
- SDK `NEFilterFlow.h`：sourceAppIdentifier 在 macOS 不可用，应验证 sourceAppAuditToken；不能直接照搬 iOS 示例或用 PID 当持久身份。
- SDK `NEFilterDataProvider.h`：分块数据判定、offset、UDP 恢复约束与已有流更新。未实测前不声称已实现阻断。

## Swift 与 SQLite

- [Swift Package manifest](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)：工具版本、平台、target、systemLibrary 和测试资源声明。
- [Swift concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)：actor 隔离和 Sendable；跨队列可变状态需同步。
- [SQLite foreign keys](https://www.sqlite.org/foreignkeys.html)：连接级启用外键与关系约束。
- [SQLite WAL](https://www.sqlite.org/wal.html)、[PRAGMA](https://www.sqlite.org/pragma.html)：单写入连接、事务持久性和 busy timeout。
- [SQLite transactions](https://www.sqlite.org/lang_transaction.html)、[EXPLAIN QUERY PLAN](https://www.sqlite.org/eqp.html)：迁移事务、查询与索引验证。

网络内容和用户流量不进入文档或日志。这里列出实现依据；实际支持与性能以 implementation-status.md 中的实测为准。

## 本地打包工具依据

本机 macOS 27.2 的 `diskutil image create from --help` 已核对，生成文件夹镜像使用 `--volumeName` 和 `--format UDZO`。构建脚本在 macOS 27 及以上使用该官方入口；较早系统保留 hdiutil 的文件夹镜像入口。开发 DMG 的实际生成结果与校验值见进度记录，不把打包成功等同于保护能力完成。
