import Foundation
import FlowQuotaCore
import FlowQuotaPlatform

extension AgentRuntime {
    func startMihomoSampling(generation: UInt64) {
        mihomoAccumulator.resetBaseline()
        mihomoProxy = MihomoProxySnapshot(status: .unavailable, message: "正在连接 Mihomo API；首帧只建立基线。")
        let controller = mihomoController
        mihomoTask = Task { [weak self] in
            while !Task.isCancelled {
                // Capture the path before I/O as well: a response spanning a path
                // change must not allocate its interval to the new network category.
                let requestScope = await self?.mihomoScope()
                do {
                    let response = try await Task.detached(priority: .utility) {
                        try controller.readConnections()
                    }.value
                    try Task.checkCancellation()
                    await self?.ingestMihomo(response, generation: generation, requestScope: requestScope)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.mihomoSamplingFailed(error, generation: generation)
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func ingestMihomo(_ response: MihomoAPIResponse, generation: UInt64,
                      capturedAt: Date = Date(), requestScope: String? = nil) async {
        guard generation == samplingGeneration else { return }
        do {
            let path = observeNetwork()
            let scope = try mihomoScope(path: path, at: capturedAt)
            guard requestScope == nil || requestScope == scope else {
                mihomoAccumulator.resetBaseline()
                return
            }
            var next = mihomoAccumulator
            let uptime = samplingTime()
            let snapshot = try next.consume(response, scope: scope, capturedAt: capturedAt,
                category: path.state.trafficCategory, uptime: uptime)
            if let category = path.state.trafficCategory {
                try await store.recordClashSources(next.sourceIncrements, at: capturedAt, category: category)
            }
            // Storage may suspend this actor; do not accept a response after pause/path change.
            guard generation == samplingGeneration, try mihomoScope(path: observeNetwork(), at: capturedAt) == scope else {
                mihomoAccumulator.resetBaseline()
                return
            }
            mihomoAccumulator = next
            mihomoProxy = snapshot
            if let category = path.state.trafficCategory {
                do {
                    let policy = try await store.trafficAlertPolicy(category: category)
                    guard generation == samplingGeneration else { return }
                    let day = try LocalDay.key(for: capturedAt, in: .current)
                    try clashAlertWindow.consume(next.sourceIncrements, start: next.sourceIntervalStart, end: uptime,
                        scope: "\(category.rawValue):\(day):\(path.generation):\(policy.version)", windowSeconds: policy.windowSeconds)
                } catch {
                    clashAlertWindow.reset()
                    mihomoSamplingFailed(error, generation: generation)
                }
            }
        } catch {
            mihomoSamplingFailed(error, generation: generation)
        }
    }

    func mihomoSamplingFailed(_ error: any Error, generation: UInt64) {
        guard generation == samplingGeneration else { return }
        // Recovery starts at a new baseline; bytes across an outage are unknown.
        mihomoAccumulator.resetBaseline()
        clashAlertWindow.reset()
        let previous = mihomoProxy
        mihomoProxy = MihomoProxySnapshot(status: previous.sampledAt == nil ? .unavailable : .stale,
            activeConnectionCount: previous.activeConnectionCount,
            uploadedBytes: previous.uploadedBytes, downloadedBytes: previous.downloadedBytes,
            sources: previous.sources, sampledAt: previous.sampledAt,
            message: "Clash 来源识别暂不可用；已观测明细保留，恢复时重建基线。\(error.localizedDescription)",
            day: previous.day, category: previous.category)
    }

    func pauseMihomoSampling() {
        mihomoAccumulator.resetBaseline()
        clashAlertWindow.reset()
        let previous = mihomoProxy
        mihomoProxy = MihomoProxySnapshot(status: .paused,
            uploadedBytes: previous.uploadedBytes, downloadedBytes: previous.downloadedBytes,
            sources: previous.sources, sampledAt: previous.sampledAt,
            message: "Flow Quota 已暂停来源采集；这不代表 Clash 已暂停。",
            day: previous.day, category: previous.category)
    }

    private func mihomoScope() -> String? {
        try? mihomoScope(path: observeNetwork(), at: Date())
    }

    private func mihomoScope(path: NetworkObservation, at date: Date) throws -> String {
        "\(try LocalDay.key(for: date, in: .current)):\(path.generation):\(path.state.rawValue)"
    }
}
