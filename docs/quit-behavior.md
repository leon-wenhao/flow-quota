# 提醒版退出流程（2026-11-06）

适用范围：Swift tools 6.0 / Swift 6、最低 macOS 14，当前 nettop 提醒版。实现入口为 `AppDelegate.applicationShouldTerminate`、`AppQuitCoordinator`、`AppState.stopForTermination` 与平台层 `AgentTerminationStop`。

## 行为与确认边界

普通退出先返回 `terminateCancel`，继续运行正常事件循环，并在独立原生窗口显示停止进度。收到停止确认后重新调用 `terminate`，第二次委托回调才返回 `terminateNow`。菜单栏按钮与 Cmd-Q 共用此入口。系统关机、重启、注销和 Quit All 根据当前 Apple Event 的 `kAEQuitReason` 识别，仍返回 `terminateLater` 并在完成后回复原系统请求，避免取消整个系统操作；等待普通退出时收到系统退出也会接管这个回复。等待中重复退出只唤起进度窗口，不重复停止；失败确认框内重复退出也不新建任务。已有配置操作尚未完成时保留操作并显示原因。

退出等待期间暂停主应用轮询，避免新请求、通知投递与退出流程互相竞争；返回应用时恢复轮询。已经发出的请求仍遵循原有取消及一次完成规则。安全框架的静态签名验证在后台任务运行，XPC 的双向代码身份要求保持不变。

停止顺序：

1. 服务已是 `notRegistered` 时无需发送停止请求，包括曾连接但后来被移除的情况。
2. 其余状态先发送原有 `.stopProtection`。正常 ACK 仍等待采样任务与 nettop 子进程回收，不注销健康服务，后台日期清理继续运行。
3. 只有连接中断或 5 秒通信超时才尝试 `try await SMAppService.unregister()`；仅当前开发提醒包且未嵌入 SystemExtensions 时允许。服务返回的业务错误、无效响应和任务取消均不触发注销。该路径只停止服务，不注册、不重启、不启动采样。
4. 必须等待异步注销成功且状态成为 `notRegistered`，才能按后台服务已退出继续关闭主应用。同步注销提交、单独的回调到达、注销失败或状态未知均不足以确认。失败信息保留停止请求与注销两阶段原因。
5. 仍无法确认时才显示“无法确认采集已停止”，用户可返回或明确选择“仅退出界面”；后者继续说明后台可能运行且不再发送提醒。

正常 ACK 与系统注销是不同确认路径：系统注销确认后台服务进程终止，不声称取得正常停机的子进程回收 ACK。Agent 自身仍使用已有 SIGTERM 清理与停机看门狗。真实系统注销延迟、异常停机后的 nettop 子进程清理未在本轮实测，不能据模拟回归声称通过。

异常恢复路径注销服务后，后台日期维护也随服务退出暂停；下次用户“连接服务”后由既有维护逻辑补清非当前日期记录。正常退出只暂停采集，保留已注册服务及日期维护。两条路径均不新增统计备份，不删除规则、偏好或当天用量，不补计停止期间流量。Sparkle 安装交接沿用独立的恢复标记及停止／注销流程，本改动不用于绕过更新前的停止确认。

## 官方依据

- Apple [NSApplicationDelegate.applicationShouldTerminate](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)) 及本机 macOS SDK 27.2 `AppKit.framework/Headers/NSApplication.h`：`terminateCancel` 表示不执行本次终止，`terminateNow` 才允许终止；`terminateLater` 需要随后调用 `reply(toApplicationShouldTerminate:)`。普通退出调整为前两者，系统退出及更新交接保留异步回复协议；同 SDK `AE.framework/Headers/AERegistry.h` 与 `AppleEvents.h` 明确了退出事件、原因参数及四个系统原因常量。并不据此推断原问题一定是主线程死锁。
- Apple [SMAppService.unregister](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister()) 及同版本 `ServiceManagement.framework/Headers/SMAppService.h` 的 `unregisterWithCompletionHandler:`：自 macOS 13 可用；异步完成发生在运行进程被终止之后，同步变体不等待进程终止。保持平台 API 与权限要求，不使用 launchctl、杀进程命令或降低身份校验作替代。
- Apple [SecStaticCodeCheckValidity](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:)) 及 `Security.framework/Headers/SecStaticCode.h`：验证签名和被封印的代码组件；每次请求独立创建和使用验证对象，移到后台任务，不跳过验证或缓存旧签名结果。

## 验证

本轮使用模拟服务覆盖健康 ACK、已注销、超时／断连恢复、等待注销、注销失败／状态未完成、业务错误、取消、不允许恢复的构建、重复退出、失败框重入、系统退出原因及延期回复、返回应用恢复轮询和显式仅退出界面。未连接实际采样服务、未执行热点计量或生成验收网络流量。完整回归 454 项通过（XCTest 37、Swift Testing 417）；arm64 与 x86_64 release 构建、严格 ad-hoc 签名检查及发布包结构审计通过。本机 Swift 6.4.2／macOS SDK 27.2；Intel 未运行，真实系统关机／注销流程未实测。日志为 `.artifacts/quit-optimization-full-tests.log`、`.artifacts/quit-optimization-build-arm64.log` 与 `.artifacts/quit-optimization-build-x64.log`。
