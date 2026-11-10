import Foundation
import FlowQuotaCore

extension AgentRuntime {
    /// Independent of sampling and UI polling, including while collection is paused.
    /// Sleep/termination cannot run code: resume/startup performs overdue maintenance.
    func startRetentionMaintenance() async throws {
        stopRetentionMaintenance()
        try await maintainCurrentDay()
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.performRetentionMaintenance()
            }
        }
    }

    func stopRetentionMaintenance() {
        retentionTask?.cancel()
        retentionTask = nil
    }

    private func maintainCurrentDay() async throws {
        let day = try LocalDay.key(for: Date(), in: .current)
        try await pruneIfNeeded(day: day)
    }

    private func performRetentionMaintenance() async {
        do {
            try await maintainCurrentDay()
        } catch {
            retentionError = error.localizedDescription
        }
    }

    func pruneIfNeeded(day: String) async throws {
        guard day != lastPrunedDay || retentionError != nil else { return }
        do {
            try await store.prunePreviousDays()
            if let previous = lastPrunedDay, previous != day {
                // Pausing must not keep yesterday's source details/windows in memory.
                accumulator.reset()
                interfaceAccumulator.reset()
                resetTrafficAlertWindows()
                mihomoAccumulator.reset()
                mihomoProxy = MihomoProxySnapshot(status: monitoring == .paused ? .paused : .unavailable,
                    message: "已清理前一天的来源明细；等待当天有效观测。")
                sampledAt = nil
                sampledAtByCategory = [:]
                interfaceSampledAt = nil
                reconciledTrafficCache.removeAll()
                reconciledTrafficErrors.removeAll()
            }
            lastPrunedDay = day
            retentionError = nil
        } catch {
            retentionError = error.localizedDescription
            throw error
        }
    }
}
