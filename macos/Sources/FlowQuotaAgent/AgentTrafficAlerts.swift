import Foundation
import FlowQuotaCore
import FlowQuotaStore

extension AgentRuntime {
    func trafficAlertPolicyChanged(_ policy: TrafficAlertPolicy, category: TrafficCategory) throws {
        trafficAlertWrites.retain(day: try LocalDay.key(for: Date(), in: .current), policy: policy, category: category)
        // Editing an inactive category must not erase the active category's window.
        if observeNetwork().state.trafficCategory == category { resetTrafficAlertWindows() }
    }

    func resetTrafficAlertWindows() {
        trafficAlertEpoch &+= 1
        interfaceAlertWindow.reset()
        applicationAlertWindow.reset()
        alertAttributionWindow.reset()
        clashAlertWindow.reset()
        alertAttributionMessage = ""
        interfaceAlertMessage = "接口短时窗口已清空；等待连续采样。"
        applicationAlertMessage = "应用短时窗口已清空；等待连续采样。"
    }

    /// Called after interface usage commits. Daily and burst checks have separate
    /// errors; failure to save an earned event never invalidates measured buckets.
    func evaluateInterfaceAlerts(day: String, uploaded: Int64, downloaded: Int64,
                                 continuous: Bool, pathGeneration: UInt64, generation: UInt64,
                                 now: Date, uptime: UInt64, category: TrafficCategory = .metered) async {
        let epoch = trafficAlertEpoch
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        let policy: TrafficAlertPolicy
        do { policy = try await store.trafficAlertPolicy(category: category) }
        catch {
            guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
            interfaceAlertWindow.reset()
            interfaceAlertMessage = "接口预警配置读取失败：\(error.localizedDescription)"
            return
        }
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        trafficAlertWrites.retain(day: day, policy: policy, category: category)
        let dailyMessage = await evaluateDailyInterfaceAlert(day: day, policy: policy,
            generation: generation, epoch: epoch, now: now, category: category)
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        var burstMessage: String
        do {
            if let limit = policy.interfaceBurstBytes {
                let (bytes, overflow) = uploaded.addingReportingOverflow(downloaded)
                guard !overflow, uploaded >= 0, downloaded >= 0 else { throw TrafficAlertError.overflow }
                let totals = try interfaceAlertWindow.consume(["interface": bytes], uptime: uptime,
                    scope: "\(category.rawValue):\(day):\(pathGeneration):\(policy.version)",
                    windowSeconds: policy.windowSeconds, continuous: continuous)
                if let usage = totals["interface"], usage.bytes >= limit {
                    try trafficAlertWrites.stage(TrafficAlertEvent(category: category, day: day, kind: .interfaceBurst,
                        sourceName: "本机计量接口", observedBytes: usage.bytes, thresholdBytes: limit,
                        windowSeconds: policy.windowSeconds, observedSeconds: usage.observedSeconds,
                        policyVersion: policy.version, occurredAt: now,
                        applications: alertAttributionWindow.snapshot(since: usage.startedAt, through: uptime,
                            scope: "\(category.rawValue):\(day):\(pathGeneration):\(policy.version)").resolvingClash(
                                clashAlertWindow.sources(since: usage.startedAt, through: uptime,
                                    scope: "\(category.rawValue):\(day):\(pathGeneration):\(policy.version)"))))
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
                                              generation: UInt64, epoch: UInt64, now: Date, category: TrafficCategory) async -> String {
        guard let limit = policy.dailyInterfaceBytes else {
            let failure = await flushTrafficAlertWrites(kind: .dailyInterface, generation: generation, epoch: epoch)
            return "每日接口预警已关闭。" + (failure.map { " 已获得的预警尚未保存：" + $0 } ?? "")
        }
        var message = "每日接口预警运行中。"
        do {
            let usage = try await store.interfaceUsage(day: day, category: category)
            guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return message }
            if let total = usage?.totalBytes, total >= limit {
                let applications: TrafficAlertApplications
                do { applications = try await store.dailyAlertApplications(day: day, category: category, observedAt: now) }
                catch { applications = .unavailable("预警触发时应用归因读取失败：\(error.localizedDescription)") }
                guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return message }
                try trafficAlertWrites.stage(TrafficAlertEvent(category: category, day: day, kind: .dailyInterface,
                    sourceName: "本机计量接口", observedBytes: total, thresholdBytes: limit,
                    windowSeconds: 0, observedSeconds: 0, policyVersion: policy.version, occurredAt: now,
                    applications: applications))
            }
        } catch { message = "每日接口预警未完成：\(error.localizedDescription)" }
        if let failure = await flushTrafficAlertWrites(kind: .dailyInterface, generation: generation, epoch: epoch) {
            message += " 每日预警尚未保存，将重试：\(failure)"
        }
        return message
    }

    private func applicationAlertEvidence(key: String, usage: WindowUsage, uptime: UInt64,
                                          scope: String) -> TrafficAlertApplications {
        let snapshot = alertAttributionWindow.snapshot(since: usage.startedAt, through: uptime,
                                                       scope: scope, sourceKey: key)
        guard snapshot.observedAt != nil else { return snapshot }
        guard snapshot.items.count == 1, snapshot.items[0].totalBytes == usage.bytes else {
            return .unavailable("触发应用的方向明细未覆盖完整预警区间；保留原预警用量。")
        }
        return snapshot.resolvingClash(clashAlertWindow.sources(since: usage.startedAt, through: uptime, scope: scope))
    }

    /// Each canonical app is checked independently. A rollback only rebases its app.
    /// Names are read at threshold crossings, not retained with every sample bucket.
    func evaluateApplicationAlerts(_ increments: [UsageIncrement], day: String,
                                   continuous: Bool, resetSources: Set<String> = [],
                                   pathGeneration: UInt64, generation: UInt64,
                                   now: Date, uptime: UInt64, category: TrafficCategory = .metered) async {
        let epoch = trafficAlertEpoch
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        let policy: TrafficAlertPolicy
        do { policy = try await store.trafficAlertPolicy(category: category) }
        catch {
            guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
            applicationAlertWindow.reset()
            alertAttributionWindow.reset()
            clashAlertWindow.reset()
            applicationAlertMessage = "应用预警配置读取失败：\(error.localizedDescription)"
            return
        }
        guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
        trafficAlertWrites.retain(day: day, policy: policy, category: category)
        // Attribution remains active when only interface alerts are enabled.
        // Its failure cannot disable either independent interface alert.
        do {
            try alertAttributionWindow.consume(increments.map {
                TrafficAlertApplication(identity: $0.identity, uploadedBytes: $0.uploadedBytes,
                                        downloadedBytes: $0.downloadedBytes)
            }, uptime: uptime, observedAt: now,
                scope: "\(category.rawValue):\(day):\(pathGeneration):\(policy.version)",
                windowSeconds: policy.windowSeconds, continuous: continuous, resetSources: resetSources)
            alertAttributionMessage = ""
        } catch { alertAttributionMessage = "预警应用归因不可用：\(error.localizedDescription)" }
        guard let limit = policy.applicationBurstBytes else {
            applicationAlertWindow.reset()
            let failure = await flushTrafficAlertWrites(kind: .applicationBurst, generation: generation, epoch: epoch)
            applicationAlertMessage = "应用短时预警已关闭。" + (failure.map { " 已获得的预警尚未保存：" + $0 } ?? "")
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
                scope: "\(category.rawValue):\(day):\(pathGeneration):\(policy.version)", windowSeconds: policy.windowSeconds,
                continuous: continuous, resetSources: resetSources)
            consumed = true
            let exceeded = totals.filter { $0.value.bytes >= limit }
            if !exceeded.isEmpty {
                let rows = try await store.snapshot(day: day, category: category)
                guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return }
                let names = Dictionary(uniqueKeysWithValues: rows.map { ($0.identity.key, $0.identity.name) })
                for (key, usage) in exceeded.sorted(by: { $0.key < $1.key }) {
                    try trafficAlertWrites.stage(TrafficAlertEvent(category: category, day: day, kind: .applicationBurst,
                        sourceKey: key, sourceName: names[key] ?? key, observedBytes: usage.bytes,
                        thresholdBytes: limit, windowSeconds: policy.windowSeconds,
                        observedSeconds: usage.observedSeconds, policyVersion: policy.version, occurredAt: now,
                        applications: applicationAlertEvidence(key: key, usage: usage, uptime: uptime,
                            scope: "\(category.rawValue):\(day):\(pathGeneration):\(policy.version)")))
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
