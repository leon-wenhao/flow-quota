import AppKit
import FlowQuotaPlatform
import Observation
import Sparkle

/// One application-lifetime controller. Initialization is offline; only the
/// settings button is allowed to begin a network check, including saved defaults.
@MainActor @Observable final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private(set) var message = "尚未检查更新"
    private(set) var errorMessage: String?
    private(set) var checking = false
    private(set) var installing = false
    private(set) var recovering = false
    private(set) var needsRecovery = false
    private(set) var lastCheck: Date?
    private(set) var readyToCheck = false
    @ObservationIgnored private var availability: NSKeyValueObservation?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let handoff: UpdateHandoff
    @ObservationIgnored private var installHandler: (() -> Void)?
    @ObservationIgnored private var targetBuild: String?
    @ObservationIgnored private var canPrepare: () -> Bool = { false }
    @ObservationIgnored private var suspend: () -> Void = {}
    @ObservationIgnored private var resume: () -> Void = {}
    @ObservationIgnored private var showRecovery: () -> Void = {}

    init(handoff: UpdateHandoff = UpdateHandoff()) {
        self.handoff = handoff
        super.init()
    }

    var readyToTerminate: Bool { handoff.ready }
    var hasStagedUpdate: Bool { targetBuild != nil }
    var hasPendingInstall: Bool { installHandler != nil }
    var canCheck: Bool { readyToCheck && !installing && !needsRecovery }
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
            Task { @MainActor [weak self] in self?.readyToCheck = enabled }
        }
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
        controller?.checkForUpdates(nil)
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates else {
            throw PlatformError.unavailable("仅支持用户主动检查更新。")
        }
        checking = true
        message = "正在检查更新…"
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        message = "发现新版本：\(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
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
        checking = false
        lastCheck = updater.lastUpdateCheckDate ?? Date()
        let failure = error.flatMap { Self.isNoUpdate($0) ? nil : "更新未完成：\($0.localizedDescription)" }
        if let failure {
            errorMessage = failure
            targetBuild = nil
            installHandler = nil
        }
        if handoff.hasRecovery && (!handoff.ready || failure != nil) {
            Task { @MainActor in
                await recover()
                // Successful service recovery must not hide the install failure.
                if errorMessage == nil { errorMessage = failure }
            }
        }
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
