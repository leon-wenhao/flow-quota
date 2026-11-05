import Foundation
import FlowQuotaCore
import FlowQuotaStore

extension AgentRuntime {
    func resetTrafficAlertWindows() {
        trafficAlertEpoch &+= 1
        interfaceAlertWindow.reset()
        applicationAlertWindow.reset()
        interfaceAlertMessage = "接口短时窗口已清空；等待连续采样。"
        applicationAlertMessage = "应用短时窗口已清空；等待连续采样。"
    }

    /// Called after interface usage commits. Daily and burst checks have separate
    /// errors; failure to save an earned event never invalidates measured buckets.
    func evaluateInterfaceAlerts(day: String, uploaded: Int64, downloaded: Int64,
                                 continuous: Bool, pathGeneration: UInt64, generation: UInt64,
                                 now: Date, uptime: UInt64) async {
        let epoch = trafficAlertEpoch
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        let policy: TrafficAlertPolicy
        do { policy = try await store.trafficAlertPolicy() }
        catch {
            guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
            interfaceAlertWindow.reset()
            interfaceAlertMessage = "接口预警配置读取失败：\(error.localizedDescription)"
            return
        }
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        trafficAlertWrites.retain(day: day, policy: policy)
        let dailyMessage = await evaluateDailyInterfaceAlert(day: day, policy: policy,
            generation: generation, epoch: epoch, now: now)
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        var burstMessage: String
        do {
            if let limit = policy.interfaceBurstBytes {
                let (bytes, overflow) = uploaded.addingReportingOverflow(downloaded)
                guard !overflow, uploaded >= 0, downloaded >= 0 else { throw TrafficAlertError.overflow }
                let totals = try interfaceAlertWindow.consume(["interface": bytes], uptime: uptime,
                    scope: "\(day):\(pathGeneration):\(policy.version)",
                    windowSeconds: policy.windowSeconds, continuous: continuous)
                if let usage = totals["interface"], usage.bytes >= limit {
                    try trafficAlertWrites.stage(TrafficAlertEvent(day: day, kind: .interfaceBurst,
                        sourceName: "本机计量接口", observedBytes: usage.bytes, thresholdBytes: limit,
                        windowSeconds: policy.windowSeconds, observedSeconds: usage.observedSeconds,
                        policyVersion: policy.version, occurredAt: now))
                }
                burstMessage = interfaceAlertWindow.isCollecting
                    ? "接口短时预警运行中；未知来源不影响接口提醒。" : "接口短时预警等待连续采样。"
            } else {
                interfaceAlertWindow.reset()
                burstMessage = "接口短时预警已关闭。"
            }
        } catch {
            interfaceAlertWindow.reset()
            burstMessage = "接口短时预警未完成：\(error.localizedDescription)"
        }
        if let failure = await flushTrafficAlertWrites(kind: .interfaceBurst, generation: generation, epoch: epoch) {
            burstMessage += " 接口预警尚未保存，将重试：\(failure)"
        }
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        interfaceAlertMessage = dailyMessage + " " + burstMessage
    }

    private func evaluateDailyInterfaceAlert(day: String, policy: TrafficAlertPolicy,
                                              generation: UInt64, epoch: UInt64, now: Date) async -> String {
        guard let limit = policy.dailyInterfaceBytes else { return "每日接口预警已关闭。" }
        var message = "每日接口预警运行中。"
        do {
            let usage = try await store.interfaceUsage(day: day)
            guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return message }
            if let total = usage?.totalBytes, total >= limit {
                try trafficAlertWrites.stage(TrafficAlertEvent(day: day, kind: .dailyInterface,
                    sourceName: "本机计量接口", observedBytes: total, thresholdBytes: limit,
                    windowSeconds: 0, observedSeconds: 0, policyVersion: policy.version, occurredAt: now))
            }
        } catch { message = "每日接口预警未完成：\(error.localizedDescription)" }
        if let failure = await flushTrafficAlertWrites(kind: .dailyInterface, generation: generation, epoch: epoch) {
            message += " 每日预警尚未保存，将重试：\(failure)"
        }
        return message
    }

    /// Each canonical app is checked independently. A rollback only rebases its app.
    /// Names are read at threshold crossings, not retained with every sample bucket.
    func evaluateApplicationAlerts(_ increments: [UsageIncrement], day: String,
                                   continuous: Bool, resetSources: Set<String> = [],
                                   pathGeneration: UInt64, generation: UInt64,
                                   now: Date, uptime: UInt64) async {
        let epoch = trafficAlertEpoch
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        let policy: TrafficAlertPolicy
        do { policy = try await store.trafficAlertPolicy() }
        catch {
            guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
            applicationAlertWindow.reset()
            applicationAlertMessage = "应用预警配置读取失败：\(error.localizedDescription)"
            return
        }
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        trafficAlertWrites.retain(day: day, policy: policy)
        guard let limit = policy.applicationBurstBytes else {
            applicationAlertWindow.reset()
            applicationAlertMessage = "应用短时预警已关闭。"
            return
        }
        var message: String
        var consumed = false
        do {
            var bytes: [String: Int64] = [:]
            for item in increments {
                let (value, overflow) = item.uploadedBytes.addingReportingOverflow(item.downloadedBytes)
                let (sum, sumOverflow) = (bytes[item.identity.key] ?? 0).addingReportingOverflow(value)
                guard !overflow, !sumOverflow, item.uploadedBytes >= 0, item.downloadedBytes >= 0 else {
                    throw TrafficAlertError.overflow
                }
                if sum > 0 { bytes[item.identity.key] = sum }
            }
            let totals = try applicationAlertWindow.consume(bytes, uptime: uptime,
                scope: "\(day):\(pathGeneration):\(policy.version)", windowSeconds: policy.windowSeconds,
                continuous: continuous, resetSources: resetSources)
            consumed = true
            let exceeded = totals.filter { $0.value.bytes >= limit }
            if !exceeded.isEmpty {
                let rows = try await store.snapshot(day: day)
                guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
                let names = Dictionary(uniqueKeysWithValues: rows.map { ($0.identity.key, $0.identity.name) })
                for (key, usage) in exceeded.sorted(by: { $0.key < $1.key }) {
                    try trafficAlertWrites.stage(TrafficAlertEvent(day: day, kind: .applicationBurst,
                        sourceKey: key, sourceName: names[key] ?? key, observedBytes: usage.bytes,
                        thresholdBytes: limit, windowSeconds: policy.windowSeconds,
                        observedSeconds: usage.observedSeconds, policyVersion: policy.version, occurredAt: now))
                }
            }
            message = applicationAlertWindow.isCollecting
                ? "应用短时预警运行中；共享下载服务不推测原始请求方。" : "应用短时预警等待连续采样。"
        } catch {
            if !consumed { applicationAlertWindow.reset() }
            // A metadata/queue write error must not
            // discard valid buckets, so their qualifying sources can retry next tick.
            message = "应用预警覆盖不完整：\(error.localizedDescription)"
        }
        if let failure = await flushTrafficAlertWrites(kind: .applicationBurst, generation: generation, epoch: epoch) {
            message += " 应用预警尚未保存，将重试：\(failure)"
        }
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        applicationAlertMessage = message
    }
}
