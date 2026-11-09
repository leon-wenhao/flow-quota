import AppKit
import FlowQuotaPlatform
import Observation
import Sparkle

/// One application-lifetime controller. Automatic probes fetch only version
/// information; Sparkle's interactive download/install flow requires a user action.
@MainActor @Observable final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private(set) var message = "尚未检查更新"
    private(set) var errorMessage: String?
    private(set) var checking = false
    private(set) var availableVersion: String?
    let automaticChecks: AutomaticUpdateChecks
    private(set) var installing = false
    private(set) var recovering = false
    private(set) var needsRecovery = false
    private(set) var lastCheck: Date?
    private(set) var readyToCheck = false
    @ObservationIgnored private let giteeFeed: @Sendable () async throws -> URL
    @ObservationIgnored let sources = UpdateSourceFallback()
    @ObservationIgnored var pendingSourceCheck: Bool?
    @ObservationIgnored var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var availability: NSKeyValueObservation?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let handoff: UpdateHandoff
    @ObservationIgnored private var installHandler: (() -> Void)?
    @ObservationIgnored private var targetBuild: String?
    @ObservationIgnored private var canPrepare: () -> Bool = { false }
    @ObservationIgnored private var suspend: () -> Void = {}
    @ObservationIgnored private var resume: () -> Void = {}
    @ObservationIgnored private var showRecovery: () -> Void = {}

    init(handoff: UpdateHandoff = UpdateHandoff(), defaults: UserDefaults = .standard,
         giteeFeed: @escaping @Sendable () async throws -> URL = { try await GiteeUpdateFeed.resolve() }) {
        self.giteeFeed = giteeFeed
        self.handoff = handoff
        automaticChecks = AutomaticUpdateChecks(defaults: defaults)
        super.init()
    }

    var readyToTerminate: Bool { handoff.ready }
    var hasStagedUpdate: Bool { targetBuild != nil }
    var hasPendingInstall: Bool { installHandler != nil }
    var canCheck: Bool { readyToCheck && !checking && !installing && !recovering && !needsRecovery }
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本"
    }

    func start(canPrepare: @escaping () -> Bool, suspend: @escaping () -> Void,
               resume: @escaping () -> Void, showRecovery: @escaping () -> Void) async {
        self.canPrepare = canPrepare
        self.suspend = suspend
        self.resume = resume
        self.showRecovery = showRecovery
        if handoff.hasRecovery { await recover() }
        guard InstallationLocation.isInApplications, Bundle.main.bundleURL.pathExtension == "app" else {
            message = "请先将 Flow Quota 安装到 Applications 后检查更新。"
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                       userDriverDelegate: nil)
        self.controller = controller
        availability = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let enabled = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.readyToCheck = enabled
                self?.continueSourceCheck()
            }
        }
        // Keep Sparkle's UI-presenting scheduler disabled. Our quiet schedule uses
        // checkForUpdateInformation(), which cannot offer/download an update.
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        controller.updater.sendsSystemProfile = false
        do { try controller.updater.start() }
        catch { errorMessage = "更新组件启动失败：\(error.localizedDescription)" }
    }

    func check() {
        guard canCheck else { return }
        errorMessage = nil
        NSApplication.shared.activate(ignoringOtherApps: true)
        showRecovery() // Keep quiet source-selection progress visible for manual checks.
        routeSourceCheck(sources.begin(manual: true))
    }

    /// Called by the existing application-lifetime loop, including after wake or
    /// reconnect. No network category/sampling gate: all connection types qualify.
    func checkAutomaticallyIfDue(at now: Date = Date()) {
        guard let updater = controller?.updater else { return }
        automaticChecks.checkIfDue(at: now,
            ready: canCheck && canPrepare() && !hasStagedUpdate && !hasPendingInstall && !updater.sessionInProgress) {
                routeSourceCheck(sources.begin(manual: false))
            }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates || (updateCheck == .updateInformation && (sources.manual || automaticChecks.enabled)) else {
            throw PlatformError.unavailable("只允许手动更新或自动查询版本信息。")
        }
        automaticChecks.recordAttempt(at: Date())
        checking = true
        errorMessage = nil
        message = "正在通过 \(sources.source) 检查更新…"
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        automaticChecks.recordSuccess(at: Date())
        message = "发现新版本：\(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        if let reason, reason.int32Value == SPUNoUpdateFoundReason.onLatestVersion.rawValue
            || reason.int32Value == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue {
            message = "当前已是最新版本"
        } else { message = error.localizedDescription }
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        // Sparkle can retain a prepared update until quit. The application
        // termination path must use the same safe handoff even without Restart.
        targetBuild = item.versionString
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        self.installHandler = installHandler
        targetBuild = item.versionString
        prepareInstallation()
        return true
    }

    func prepareInstallation() {
        guard installHandler != nil else { return }
        Task { @MainActor in
            guard await prepareForTermination() else { return }
            let handler = self.installHandler
            self.installHandler = nil
            handler?()
        }
    }

    func prepareForTermination() async -> Bool {
        guard !installing, let targetBuild else { return false }
        guard canPrepare() else {
            errorMessage = "请等待当前操作完成，再重试安装。"
            showRecovery()
            return false
        }
        installing = true
        errorMessage = nil
        suspend()
        do {
            try await handoff.prepare(targetBuild: targetBuild)
            message = "采集已停止，正在安装并重启…"
            return true
        } catch {
            installing = false
            needsRecovery = handoff.hasRecovery
            errorMessage = "安装准备失败：\(error.localizedDescription) 请重试安装，或恢复采集后重启应用。"
            resume()
            showRecovery()
            return false
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if updateCheck == .updateInformation && sources.probing {
            let failure = error.flatMap { Self.isNoUpdate($0) ? nil : $0.localizedDescription }
            lastCheck = Date()
            if failure == nil { automaticChecks.recordSuccess(at: Date()) }
            routeSourceCheck(sources.probeFinished(failure: failure,
                fallbackAllowed: sources.manual || automaticChecks.enabled))
            return
        }
        checking = false
        let completedAt = Date()
        lastCheck = completedAt
        if error == nil || error.map(Self.isNoUpdate) == true {
            automaticChecks.recordSuccess(at: completedAt)
        }
        let failure = error.flatMap { Self.isNoUpdate($0) ? nil : "更新未完成：\($0.localizedDescription)" }
        if let failure {
            message = "检查或更新未完成"
            errorMessage = failure
            if updateCheck == .updates {
                targetBuild = nil
                installHandler = nil
            }
        }
        // A quiet probe never enters installation or service recovery.
        guard updateCheck != .updateInformation else { return }
        if handoff.hasRecovery && (!handoff.ready || failure != nil) {
            Task { @MainActor in
                await recover()
                // Successful service recovery must not hide the install failure.
                if errorMessage == nil { errorMessage = failure }
            }
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { sources.feedURL?.absoluteString }

    private func routeSourceCheck(_ next: UpdateSourceFallback.Next) {
        switch next {
        case .probe, .interactive:
            checking = true
            pendingSourceCheck = next == .interactive
            Task { @MainActor [weak self] in self?.continueSourceCheck() }
        case .resolveGitee:
            message = "GitHub 检查失败，正在尝试 Gitee…"
            sourceTask = Task { @MainActor [weak self] in
                do {
                    guard let load = self?.giteeFeed else { return }
                    let url = try await load()
                    guard let self else { return }
                    routeSourceCheck(sources.resolvedGitee(url))
                } catch {
                    guard let self else { return }
                    routeSourceCheck(sources.giteeFailed(error.localizedDescription))
                }
            }
        case .done:
            checking = false
        case .failed(let failure):
            checking = false
            message = "检查更新未完成"
            errorMessage = failure
            if sources.manual { showRecovery() }
        }
    }

    private func continueSourceCheck() {
        guard let interactive = pendingSourceCheck, let updater = controller?.updater,
              updater.canCheckForUpdates, !updater.sessionInProgress else { return }
        pendingSourceCheck = nil
        if !interactive && !sources.manual && !automaticChecks.enabled {
            sources.cancel()
            checking = false
            message = "自动检查已关闭"
            return
        }
        if interactive { controller?.checkForUpdates(nil) }
        else { updater.checkForUpdateInformation() }
    }

    private static func isNoUpdate(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue
    }

    func recover(allowStale: Bool = false, discard: Bool = false) async {
        guard !recovering else { return }
        recovering = true
        suspend()
        defer { recovering = false; resume() }
        do {
            if discard { try await handoff.discardKeepingPaused() }
            else { try await handoff.recover(allowStale: allowStale) }
            needsRecovery = false
            installing = false
            errorMessage = nil
            if handoff.hasRecovery == false { message = "已恢复更新前的服务状态" }
        } catch {
            installing = false
            needsRecovery = true
            errorMessage = "服务恢复失败：\(error.localizedDescription)"
            showRecovery()
        }
    }
}
