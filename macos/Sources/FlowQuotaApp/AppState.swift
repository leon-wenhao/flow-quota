import AppKit
import FlowQuotaCore
import FlowQuotaPlatform
import Observation

/// Service snapshots and serialized UI mutations. The AppDelegate owns background polling.
@MainActor @Observable
final class AppState {
    let notifications = NotificationPermission()
    let reminderDelivery: ReminderDelivery
    let trafficAlertDelivery: TrafficAlertDelivery
    var selectedTrafficCategory: TrafficCategory = .metered
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
    private(set) var updateState: UpdateCheckState = .idle
    private(set) var lastUpdateCheckAt: Date?
    private(set) var downloadedUpdateURL: URL?
    @ObservationIgnored let client: any AgentServiceClient
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    init(client: any AgentServiceClient = AgentClient(),
         scheduler: any ReminderNotificationScheduling = SystemReminderScheduler()) {
        self.client = client
        reminderDelivery = ReminderDelivery(client: client, scheduler: scheduler)
        trafficAlertDelivery = TrafficAlertDelivery(client: client, scheduler: scheduler)
    }

    var busy: Bool { operation != nil }
    var updateChecking: Bool { updateState == .checking }
    var currentVersionText: String {
        let version = AppVersion.current
        return version.marketingString
    }
    var canConfigureNetwork: Bool { connected && snapshotIsCurrent && !busy && !quitRequested }
    var canEdit: Bool { canConfigureNetwork && (selectedTrafficCategory == .metered || categorySnapshot != nil) }
    var snapshotIsCurrent: Bool {
        guard let snapshot, !snapshotExpired else { return false }
        let age = Date().timeIntervalSince(snapshot.generatedAt)
        guard let today = Self.localDay(),
              let snapshotDay = try? LocalDay.key(for: snapshot.generatedAt, in: .current) else { return false }
        return (-5...15).contains(age) && snapshotDay == today
    }
    // Only .hotspot acknowledges a manual mark; automatic cost signals are distinct.
    var hotspotMarked: Bool { connected && snapshotIsCurrent && snapshot?.network == .hotspot }
    private var currentNetwork: NetworkState? {
        connected && snapshotIsCurrent ? snapshot?.network : nil
    }
    var showsHotspotControl: Bool { currentNetwork != .expensive }
    var networkDetail: String {
        switch currentNetwork {
        case .expensive:
            return "系统报告高成本网络；这不表示已确认手机热点、设备或运营商。计入热点／高成本类，统计与普通网络分开。"
        case .hotspot:
            return "服务已确认手动标记；此连接计入热点／高成本类，统计与普通网络分开。"
        case .ordinary:
            return "当前连接计入普通网络类，独立统计；提醒默认关闭，可单独设置。如实际为手机热点，可手动修正分类。"
        case .unknown, nil:
            return "当前网络状态不可用，不分配新增流量；已保存的两类今日累计保留。"
        }
    }
    var usageAvailable: Bool { applicationUsageAvailable(for: selectedTrafficCategory) }
    func applicationUsageAvailable(for category: TrafficCategory) -> Bool {
        guard connected, snapshotIsCurrent, let snapshot else { return false }
        if let data = snapshot.usage(for: category) { return data.applicationsAvailable }
        return category == .metered && snapshot.sampledAt != nil
            && (snapshot.monitoring == .collecting || snapshot.monitoring == .paused)
    }
    var unavailableReason: String {
        if !networkUnavailableReason.isEmpty { return networkUnavailableReason }
        return ""
    }
    var networkUnavailableReason: String {
        if quitRequested { return "正在等待停止采集的确认。" }
        if busy { return "正在等待服务确认，请稍候。" }
        if !connected { return "本地服务未连接。请先启用服务或重试连接。" }
        if !snapshotIsCurrent { return "服务数据已过期，请刷新后再修改。" }
        return ""
    }
    var applications: [ApplicationSnapshot] {
        categoryApplications.filter {
            SystemProcessClassification(identity: $0.identity).visibleInApplicationUsage
        }.sorted {
            let left = knownUsage($0) ?? -1
            let right = knownUsage($1) ?? -1
            return left == right ? $0.identity.key < $1.identity.key : left > right
        }
    }
    var totalUsage: Int64? {
        guard connected, snapshotIsCurrent, let usage = categoryInterfaceUsage,
              usage.day == Self.localDay() else { return nil }
        return usage.totalBytes
    }
    func knownUsage(_ app: ApplicationSnapshot, category: TrafficCategory? = nil) -> Int64? {
        guard applicationUsageAvailable(for: category ?? selectedTrafficCategory),
              app.usage.appKey == app.identity.key,
              app.usage.day == Self.localDay(),
              app.usage.uploadedBytes >= 0, app.usage.downloadedBytes >= 0 else { return nil }
        return UsageFormatter.total([app.usage.uploadedBytes, app.usage.downloadedBytes])
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
            if snapshotIsCurrent && !quitRequested { await deliverTrafficAlerts(next) }
            if snapshotIsCurrent && next.monitoring == .collecting && !quitRequested {
                await reminderDelivery.deliver(next.notifications) { [weak self] notification in
                    guard let self else { return false }
                    // Permission and scheduling calls suspend. Recheck the newest snapshot,
                    // including pause, expiry and queue changes, before scheduling or ACK.
                    return self.connected && self.snapshotIsCurrent && !self.quitRequested
                        && self.snapshot?.monitoring == .collecting
                        && self.snapshot?.notifications.contains(where: { $0.id == notification.id }) == true
                }
            }
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            connected = false
            connectionError = "无法读取本地服务：\(error.localizedDescription)"
        }
    }

    func refreshOnce() {
        guard !busy, !refreshing else { return }
        Task { await refresh() }
    }

    func checkForUpdates() {
        guard !updateChecking else { return }
        updateState = .checking
        let current = AppVersion.current
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = try? AppVersion(version: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
        updateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.updateTask = nil }
            do {
                let result = try await UpdateChecker().check(current: current, systemVersion: systemVersion)
                guard !Task.isCancelled else { return }
                self.lastUpdateCheckAt = Date()
                switch result {
                case .upToDate:
                    self.updateState = .upToDate
                case .available(let release):
                    self.updateState = .available(release)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.lastUpdateCheckAt = Date()
                self.updateState = .failed("检查更新失败：\(error.localizedDescription)")
            }
        }
    }

    func downloadAndInstall(_ release: UpdateRelease) {
        downloadedUpdateURL = nil
        perform("正在下载更新") { state in
            let path = try await UpdateInstaller.downloadAndOpen(release)
            state.downloadedUpdateURL = path
            state.notice = "更新包已下载并打开。请将 Flow Quota.app 拖到 Applications 文件夹。首次打开若被拦截，请到系统设置的隐私与安全性中选择“仍要打开”。"
        }
    }

    func enableAgent() {
        perform("正在启用本地服务") { state in
            try await state.client.enableAgent()
            state.notice = "服务已启用并请求恢复采集；实际采样状态以最新快照为准。"
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

    func save(appKey: String, rule: QuotaRule, category: TrafficCategory? = nil, acknowledged: @escaping @MainActor () -> Void) {
        let category = category ?? selectedTrafficCategory
        guard canConfigureNetwork, category == .metered || snapshot?.usage(for: category) != nil else { return }
        let rows = snapshot?.usage(for: category)?.applications ?? (category == .metered ? snapshot?.applications ?? [] : [])
        guard let current = rows.first(where: { $0.identity.key == appKey }),
              (current.rule?.version ?? 0) < Int64.max,
              rule.version == (current.rule?.version ?? 0) + 1 else {
            errorMessage = "规则版本已变化。请返回列表重新打开编辑页。"
            return
        }
        perform("正在保存规则") { state in
            try await state.client.saveRule(appKey: appKey, rule: rule, category: category)
            state.notice = "\(category.title)提醒配置已持久化（版本 \(rule.version)）。"
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

    func reportNotice(_ message: String) { notice = message }
    func reportError(_ message: String) { errorMessage = message }

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
        perform("正在停止采集") { state in
            do {
                try await state.client.stopProtection()
                reply(true)
            } catch {
                state.quitRequested = false
                state.errorMessage = "停止采集失败：\(error.localizedDescription)"
                reply(false)
            }
        }
    }

    func perform(_ name: String, body: @escaping @MainActor (AppState) async throws -> Void) {
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

    // Expire stale menu-bar values independently of background polling failures.
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

    static func localDay() -> String? {
        try? LocalDay.key(for: Date(), in: .current)
    }
}
