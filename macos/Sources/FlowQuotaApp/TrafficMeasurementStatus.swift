import FlowQuotaCore
import SwiftUI

/// A discrepancy is visible evidence, never an invented app identity or billable row.
struct TrafficMeasurementStatus: View {
    let total: Int64?
    let processes: Int64?

    var body: some View {
        Text(message).font(.caption).foregroundStyle(comparison == .equal ? Color.secondary : .orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var comparison: TrafficMeasurementComparison {
        TrafficMeasurementComparison(total: total, sources: processes)
    }

    private var message: String {
        switch comparison {
        case .unavailable:
            total == nil ? "接口总量未知；已观测进程记录仍保留，不能代替总量。"
                : "总量已记录，但应用来源暂不可用；全部用量保留，来源待确认。"
        case .equal:
            "接口与进程观测数值一致；来源仍可能重叠，不能据此证明逐字节对应。"
        case .unexplained(let bytes):
            "未识别／计量差额：\(UsageFormatter.bytes(bytes))。已包含在总量内；可能包含未识别来源、采样时间差及协议开销，不能认定为某个应用的用量。"
        case .overlapping(let bytes):
            "进程观测合计比接口总量多 \(UsageFormatter.bytes(bytes))，存在重复观测或时段差异；保留全部记录，不重复计入 Mac 总量。"
        }
    }
}
