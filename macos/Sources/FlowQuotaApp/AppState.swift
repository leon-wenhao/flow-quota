import AppKit
import FlowQuotaCore
import FlowQuotaPlatform
import Observation

/// One UI client, one visible-panel poller and at most one mutation. No UI persistence of the ledger.
@MainActor @Observable
final class AppState {
    let notifications = NotificationPermission()
    private(set) var snapshot: AgentSnapshot?
    private(set) var connected = false
    private(set) var everConnected = false
    private(set) var refreshing = false
    private(set) var snapshotExpired = true
    private(set) var operation: String?
    private(set) var errorMessage: String?
    private(set) var connectionError: String?
    private(set) var notice: String?
    private(set) var quitRequested = false
    @ObservationIgnored private let client: any AgentServiceClient
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    init(client: any AgentServiceClient = AgentClient()) { self.client = client }

    var busy: Bool { operation != nil }
    var canConfigureNetwork: Bool { connected && snapshotIsCurrent && !busy && !quitRequested }
    var canEdit: Bool { canConfigureNetwork && snapshot?.readiness == .ready }
    var snapshotIsCurrent: Bool {
        guard let snapshot, !snapshotExpired else { return false }
        let age = Date().timeIntervalSince(snapshot.generatedAt)
        guard let today = Self.localDay(),
              let snapshotDay = try? LocalDay.key(for: snapshot.generatedAt, in: .current) else { return false }
        return (-5...15).contains(age) && snapshotDay == today
    }
    // In the current agent contract .hotspot means an acknowledged manual path mark.
    // NWPath.isExpensive alone remains .unknown and is described by the service message.
    var hotspotMarked: Bool { connected && snapshotIsCurrent && snapshot?.network == .hotspot }
    var usageAvailable: Bool { connected && snapshotIsCurrent && snapshot?.readiness == .ready }
    var unavailableReason: String {
        if !networkUnavailableReason.isEmpty { return networkUnavailableReason }
        if snapshot?.readiness != .ready { return "保护组件尚未就绪，无法确认额度生效。请完成安装与系统批准。" }
        return ""
    }
    var networkUnavailableReason: String {
        if quitRequested { return "正在等待停止保护的确认。" }
        if busy { return "正在等待服务确认，请稍候。" }
        if !connected { return "本地服务未连接。请先启用服务或重试连接。" }
        if !snapshotIsCurrent { return "服务数据已过期，请刷新后再修改。" }
        return ""
    }
    var applications: [ApplicationSnapshot] {
        (snapshot?.applications ?? []).sorted {
            let left = knownUsage($0) ?? -1
            let right = knownUsage($1) ?? -1
            return left == right ? $0.identity.key < $1.identity.key : left > right
        }
    }
    var totalUsage: Int64? {
        guard usageAvailable, !applications.isEmpty else { return nil }
        let values = applications.compactMap { knownUsage($0) }
        guard values.count == applications.count else { return nil }
        return UsageFormatter.total(values)
    }
    func knownUsage(_ app: ApplicationSnapshot) -> Int64? {
        guard usageAvailable,
              app.usage.appKey == app.identity.key,
              app.usage.day == Self.localDay(),
              app.usage.uploadedBytes >= 0, app.usage.downloadedBytes >= 0 else { return nil }
        return UsageFormatter.total([app.usage.uploadedBytes, app.usage.downloadedBytes])
    }

    // The view cancels polling when its window resigns. The client cancels its XPC
    // await; late replies are discarded and cannot overwrite a newer snapshot.
    func pollWhileVisible() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshing = true
        defer { if refreshGeneration == generation { refreshing = false } }
        do {
            let next = try await client.fetchSnapshot()
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            snapshot = next
            scheduleExpiry(for: next.generatedAt)
            connected = true
            connectionError = nil
            everConnected = true
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            connected = false
            connectionError = "无法读取本地服务：\(error.localizedDescription)"
        }
    }

    func refreshOnce() {
        perform("正在读取服务状态") { state in await state.refresh() }
    }

    func enableAgent() {
        perform("正在启用本地服务") { state in
            try await state.client.enableAgent()
            state.notice = "注册请求已完成；是否需要系统批准以服务状态和系统设置为准。"
            await state.refresh()
        }
    }

    func repairDevelopmentAgent() {
        perform("正在修复开发服务") { state in
            try await state.client.repairDevelopmentAgent()
            state.notice = "开发服务已重新注册；连接结果以最新服务状态为准。"
            await state.refresh()
        }
    }

    func save(appKey: String, rule: QuotaRule, acknowledged: @escaping @MainActor () -> Void) {
        guard canEdit else { return }
        guard let current = snapshot?.applications.first(where: { $0.identity.key == appKey }),
              (current.rule?.version ?? 0) < Int64.max,
              rule.version == (current.rule?.version ?? 0) + 1 else {
            errorMessage = "规则版本已变化。请返回列表重新打开编辑页。"
            return
        }
        perform("正在保存规则") { state in
            try await state.client.saveRule(appKey: appKey, rule: rule)
            state.notice = "服务已确认接收规则（版本 \(rule.version)）。"
            acknowledged()
            await state.refresh()
        }
    }

    func setHotspotOverride(_ marked: Bool) {
        guard canConfigureNetwork else { return }
        perform("正在更新热点标记") { state in
            try await state.client.setHotspotOverride(marked)
            state.notice = marked ? "服务已确认当前连接的手动热点标记。" : "服务已确认取消手动标记；恢复自动判断。"
            await state.refresh()
        }
    }

    func clearMessages() { errorMessage = nil; notice = nil }

    func requestQuit() { NSApplication.shared.terminate(nil) }

    /// Also used by Cmd-Q and system termination, preventing a bypass of the stop acknowledgment.
    func stopForTermination(reply: @escaping @MainActor (Bool) -> Void) {
        guard !busy else {
            errorMessage = "操作尚未结束。请等待服务确认后再退出。"
            reply(false)
            return
        }
        quitRequested = true
        perform("正在停止保护") { state in
            do {
                try await state.client.stopProtection()
                reply(true)
            } catch {
                state.quitRequested = false
                state.errorMessage = "停止保护失败：\(error.localizedDescription)"
                reply(false)
            }
        }
    }

    private func perform(_ name: String, body: @escaping @MainActor (AppState) async throws -> Void) {
        guard !busy else { return }
        clearMessages()
        operation = name
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operation = nil; self.actionTask = nil }
            do { try await body(self) }
            catch { self.errorMessage = "\(name)失败：\(error.localizedDescription)" }
        }
    }

    // A single local timer invalidates menu-bar values even while the panel does not poll.
    // Use the calendar's day boundary, which also handles daylight-saving transitions.
    private func scheduleExpiry(for generatedAt: Date) {
        expiryTask?.cancel()
        snapshotExpired = false
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let midnight = calendar.dateInterval(of: .day, for: now)?.end.timeIntervalSince(now) ?? 0
        let seconds = max(0, min(15 - now.timeIntervalSince(generatedAt), midnight))
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.snapshotExpired = true
            self?.expiryTask = nil
        }
    }

    private static func localDay() -> String? {
        try? LocalDay.key(for: Date(), in: .current)
    }
}
