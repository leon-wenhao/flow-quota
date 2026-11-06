import Foundation
import FlowQuotaCore
import FlowQuotaPlatform

extension AgentRuntime {
    /// Interface totals have their own cadence and survive nettop attribution
    /// failures. The service actor serializes baselines and commits, never the UI.
    func startInterfaceSampling(generation: UInt64) {
        interfaceAccumulator.reset()
        interfaceAlertWindow.reset()
        interfaceSampledAt = nil
        interfaceMessage = "接口采集正在启动；首帧只建基线，不回填历史应用用量。"
        interfaceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleInterface(path: self.observeNetwork(), generation: generation)
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    /// The explicit observation/clock arguments let tests exercise the complete
    /// persistence path without a system counter read or any generated traffic.
    func sampleInterface(path: NetworkObservation, generation: UInt64,
                         now: Date = Date(), uptime: UInt64? = nil) async {
        guard generation == samplingGeneration, !Task.isCancelled else { return }
        let uptime = uptime ?? samplingTime()
        guard let category = path.state.trafficCategory else {
            interfaceAccumulator.reset()
            interfaceAlertWindow.reset()
            interfaceSampledAt = nil
            interfaceMessage = "当前网络未知；保留两类今日接口用量，不分配新增流量。"
            return
        }
        guard case .selected(let index) = path.interfaceSelection else {
            interfaceAccumulator.reset()
            interfaceAlertWindow.reset()
            interfaceSampledAt = nil
            if case .unavailable(let reason) = path.interfaceSelection {
                interfaceMessage = reason.message + "已有今日总量保留，本段流量未知。"
            }
            return
        }
        do {
            let day = try LocalDay.key(for: now, in: .current)
            // Retention must still run if nettop attribution and the UI are absent.
            try await pruneIfNeeded(day: day)
            guard generation == samplingGeneration, !Task.isCancelled else { return }
            let counter = try interfaceReader.read(interfaceIndex: index)
            guard counter.interfaceIndex == index else {
                throw InterfaceCounterError.interfaceUnavailable(index)
            }
            guard observeNetwork().generation == path.generation else {
                interfaceAccumulator.reset()
                interfaceAlertWindow.reset()
                interfaceSampledAt = nil
                interfaceMessage = "读取期间网络发生变化，已丢弃本段并重建基线。"
                return
            }
            var next = interfaceAccumulator
            let delta = try next.consume(counter,
                scope: InterfaceTrafficScope(day: day, pathGeneration: path.generation, category: category), uptime: uptime)
            // A zero baseline creates a known starting point. It never converts
            // the existing application ledger into interface traffic.
            try await store.recordSample(day: day, increments: [], interfaceIncrement:
                InterfaceUsage(day: day, uploadedBytes: delta.uploadedBytes,
                               downloadedBytes: delta.downloadedBytes), category: category,
                interfaceObservedAt: delta.rebaselined ? nil : now)
            guard generation == samplingGeneration else { return }
            guard observeNetwork().generation == path.generation else {
                interfaceAccumulator.reset()
                interfaceAlertWindow.reset()
                interfaceSampledAt = nil
                interfaceMessage = "网络已切换；保留已提交总量，后续重新建立接口基线。"
                return
            }
            interfaceAccumulator = next
            interfaceSampledAt = now
            interfaceSampledCategory = category
            await evaluateInterfaceAlerts(day: day, uploaded: delta.uploadedBytes, downloaded: delta.downloadedBytes,
                continuous: !delta.rebaselined, pathGeneration: path.generation, generation: generation,
                now: now, uptime: uptime, category: category)
            guard generation == samplingGeneration else { return }
            interfaceMessage = delta.rebaselined
                ? "已重建物理接口基线；此前或间断期间的流量未知。"
                : "物理接口收发增量独立累计；包含局域网通信及协议开销，不等同运营商扣费。"
        } catch {
            // Do not advance a baseline after a failed/uncertain commit. A retry
            // starts fresh instead of replaying and potentially double charging.
            guard generation == samplingGeneration else { return }
            interfaceAccumulator.reset()
            interfaceAlertWindow.reset()
            interfaceSampledAt = nil
            interfaceMessage = "接口总量暂不可用：\(error.localizedDescription) 已有今日总量保留，本段流量未知。"
        }
    }

    func interfaceStatusMessage(at now: Date) -> String {
        if let last = interfaceSampledAt, now.timeIntervalSince(last) > 8, interfaceTask != nil {
            return "接口采样已过期；仅显示之前保存的今日总量，间断流量未知。"
        }
        return interfaceMessage
    }
}
