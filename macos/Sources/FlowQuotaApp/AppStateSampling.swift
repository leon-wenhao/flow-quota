import Foundation

extension AppState {
    /// Unknown on stale/disconnected snapshots or an older service. Application
    /// attribution failure alone must not turn off a still-running interface sampler.
    var samplingEnabled: Bool? {
        guard connected, snapshotIsCurrent else { return nil }
        return snapshot?.samplingEnabled
    }

    var canChangeSampling: Bool { samplingEnabled != nil && !busy && !quitRequested }

    func setSamplingEnabled(_ enabled: Bool) {
        guard canChangeSampling, samplingEnabled != enabled else { return }
        if enabled {
            enableAgent()
        } else {
            perform("正在暂停采集") { state in
                try await state.client.stopProtection()
                state.reportNotice("服务已确认暂停采集；保留今日用量，暂停期间流量未知。")
                await state.refresh()
            }
        }
    }
}
