import Foundation
import FlowQuotaCore

/// Interface totals have their own source and validity. Application attribution can
/// overlap (for example with a proxy), so it must never fill a missing interface total.
extension AppState {
    var interfaceUsageAvailable: Bool { totalUsage != nil }

    /// A fresh service snapshot may contain a durable daily total while sampling is
    /// paused or no interface is available. Keep that value, with explicit context.
    var interfaceUsageIsPreserved: Bool {
        guard interfaceUsageAvailable, let snapshot else { return false }
        // Application sampler failure does not stop independent interface sampling.
        return snapshot.monitoring == .paused || snapshot.network.trafficCategory != selectedTrafficCategory
            || !interfaceSampleIsCurrent
    }

    var interfaceUsageReason: String {
        guard connected else { return "接口总量未知：本地服务未连接。" }
        guard snapshotIsCurrent else { return "接口总量未知：服务快照已过期或不属于今天，请刷新。" }
        guard let usage = categoryInterfaceUsage else {
            return "接口总量未知：尚无有效的当日接口累计；应用用量不会用于补齐总量。"
        }
        guard usage.day == Self.localDay() else { return "接口总量未知：接口累计日期与今天不符。" }
        guard usage.totalBytes != nil else { return "接口总量未知：字节计数为负数或合计超出整数范围。" }
        if snapshot?.monitoring == .paused { return "采集已暂停 · 保留今日已观测接口总量。" }
        if interfaceUsageIsPreserved {
            return "保留今日已观测接口总量；当前采样未就绪或接口不可用，请查看接口服务说明。"
        }
        return "累计仅覆盖已观测区间；当前接口采集状态以服务说明为准。"
    }

    var interfaceServiceMessage: String {
        guard let message = categorySnapshot?.interfaceMessage ?? (selectedTrafficCategory == .metered ? snapshot?.interfaceMessage : nil),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "接口总量尚未就绪。"
        }
        return message
    }

    var interfaceSampleTimeText: String {
        guard let date = categoryInterfaceSampledAt else { return "接口最近采样：尚无有效采样时间" }
        return "接口最近采样：\(date.formatted(date: .abbreviated, time: .standard))"
    }

    var menuBarUsageText: String { UsageFormatter.compactBytes(totalUsage) }

    var menuBarUsageAccessibilityLabel: String {
        "Flow Quota，今日\(selectedTrafficCategory.title)接口总量：\(UsageFormatter.bytes(totalUsage))。\(interfaceUsageReason)"
    }

    var interfaceMenuHelp: String {
        "今日\(selectedTrafficCategory.title)接口总量：\(UsageFormatter.bytes(totalUsage))。\(interfaceUsageReason)\n"
            + "\(interfaceServiceMessage)\n\(interfaceSampleTimeText)\n"
            + "本机物理接口上传＋下载观测增量，包含局域网流量与协议开销；"
            + "不含手机自身或其他设备的流量，不等于运营商账单。接口总量与应用归因各自按配置判断提醒。"
    }

    private var interfaceSampleIsCurrent: Bool {
        guard let sampledAt = categoryInterfaceSampledAt,
              let day = try? LocalDay.key(for: sampledAt, in: .current),
              day == Self.localDay() else { return false }
        return (-5...8).contains(Date().timeIntervalSince(sampledAt))
    }
}
