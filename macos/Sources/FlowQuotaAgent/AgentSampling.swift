import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import FlowQuotaStore

extension AgentRuntime {
    func startMonitoring() async {
        if samplingTask != nil || interfaceTask != nil {
            let lastActivity = sampledAt ?? samplingStartedAt ?? Date()
            guard monitoring == .failed || Date().timeIntervalSince(lastActivity) > 12 else { return }
            await stopMonitoring()
            guard samplingTask == nil, interfaceTask == nil else { return }
        }
        resetTrafficAlertWindows()
        samplingGeneration &+= 1
        let generation = samplingGeneration
        let source = NettopSampler()
        sampler = source
        accumulator.reset()
        sampledAt = nil
        samplingStartedAt = Date()
        monitoring = .unavailable
        monitoringMessage = "采集正在启动；首帧只建立基线，不补算启动前流量。"
        startInterfaceSampling(generation: generation)
        startMihomoSampling(generation: generation)
        samplingTask = Task { [weak self] in
            do {
                for try await frame in source.frames() {
                    try Task.checkCancellation()
                    try await self?.ingest(frame, generation: generation)
                }
            } catch is CancellationError {
                // Explicit pause already updates status and invalidates this generation.
            } catch {
                await self?.samplingFailed(error, generation: generation)
            }
        }
    }

    func stopMonitoring() async {
        resetTrafficAlertWindows()
        samplingGeneration &+= 1
        let stoppedGeneration = samplingGeneration
        samplingTask?.cancel()
        interfaceTask?.cancel()
        mihomoTask?.cancel()
        let stoppedMihomoTask = mihomoTask
        pauseMihomoSampling()
        let stoppedInterfaceTask = interfaceTask
        interfaceAccumulator.reset()
        interfaceMessage = "接口采集已暂停；保留今天已观测总量，暂停期间未知。"
        let source = sampler
        source?.stop()
        let task = samplingTask
        accumulator.reset()
        monitoring = .paused
        monitoringMessage = "已停止采集；停止期间流量未知，网络连接不受影响。"
        await task?.value
        await source?.stopAndWait()
        await stoppedInterfaceTask?.value
        await stoppedMihomoTask?.value
        if stoppedGeneration == samplingGeneration {
            samplingTask = nil
            sampler = nil
            interfaceTask = nil
            mihomoTask = nil
        }
        // A stopping generation cannot commit after this ACK; no filter is installed.
    }

    func ingest(_ frame: NettopFrame, generation: UInt64) async throws {
        guard generation == samplingGeneration else { return }
        let now = Date()
        let day = try LocalDay.key(for: now, in: .current)
        let capturedDay = try LocalDay.key(for: frame.capturedAt, in: .current)
        let path = observeNetwork()
        // Midnight/path changes and sleep gaps are unknowable intervals, never backfilled.
        guard capturedDay == day, now.timeIntervalSince(frame.capturedAt) <= 8 else {
            accumulator.reset()
            applicationAlertWindow.reset()
            gaps += 1
            monitoringMessage = "采样间隔跨日或过长，已重建基线；间断流量未知。"
            return
        }
        try await pruneIfNeeded(day: day)
        guard generation == samplingGeneration else { return }
        let resolver = ProcessIdentityResolver()
        let resolved = frame.counters.compactMap { resolver.resolve($0, capturedAt: frame.capturedAt) }
        var next = accumulator
        let result = try next.consume(resolved, scope: "\(day):\(path.generation):\(path.state.rawValue)",
                                      sequence: frame.sequence, uptime: frame.uptime,
                                      countTraffic: path.state.countsTraffic, capturedAt: frame.capturedAt)
        if result.rebaselined, sampledAt != nil { gaps += 1 }
        let increments = result.increments.map {
            UsageIncrement(identity: $0.identity, uploadedBytes: $0.uploadedBytes, downloadedBytes: $0.downloadedBytes)
        }
        // Advance baselines only after the entire batch commits. A DB failure stops
        // this source rather than ambiguously replaying a partially observed interval.
        if let category = path.state.trafficCategory {
            try await store.recordSample(day: day, increments: increments, category: category,
                applicationObservedAt: frame.capturedAt, observedApplicationKeys: result.observedSourceKeys)
            sampledAtByCategory[category] = frame.capturedAt
        }
        guard generation == samplingGeneration else { return }
        accumulator = next
        sampledAt = frame.capturedAt
        monitoring = .collecting
        monitoringMessage = path.state.countsTraffic
            ? "正在按网络类别分别累计观测用量，达到阈值仅通知，不阻断。"
            : "采集运行中；网络未知，当前流量不分配到任一类别。"
        let unresolved = frame.counters.count - resolved.count
        if let category = path.state.trafficCategory {
            await evaluateApplicationAlerts(increments, day: day,
                continuous: !result.rebaselined, resetSources: result.resetSourceKeys,
                pathGeneration: path.generation, generation: generation, now: now, uptime: frame.uptime, category: category)
        }
        guard generation == samplingGeneration else { return }
        coverageMessage = "分别累计服务运行期间的热点／高成本与普通网络增量；启动前及间断流量未知。"
            + "应用按路径归并，代理/TUN 归属与重复尚不能保证。"
            + "本次未归属进程 \(unresolved)，计数回退 \(result.resetProcesses)，重新建立基线 \(gaps) 次。"
    }

    private func samplingFailed(_ error: any Error, generation: UInt64) {
        guard generation == samplingGeneration else { return }
        sampler?.stop()
        sampler = nil
        samplingTask = nil
        accumulator.reset()
        applicationAlertWindow.reset()
        applicationAlertMessage = "应用采样失败；应用短时窗口已清空，接口预警独立运行。"
        monitoring = .failed
        monitoringMessage = "采集失败：\(error.localizedDescription) 请重新启用采集；中断期间用量未知。"
    }
}
