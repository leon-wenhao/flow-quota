import Foundation
import FlowQuotaCore

struct UsageChartValue: Identifiable, Equatable {
    let id: String
    let label: String
    let bytes: Int64

    var plottedValue: Double { Double(bytes) }
}

struct UsageChartData: Equatable {
    let interfaceValues: [UsageChartValue]
    let applicationValues: [UsageChartValue]
    let dailyInterfaceThreshold: Int64?
    let applicationPie: UsagePieData?

    static func make(interfaceUsage: InterfaceUsage?, applications: [ApplicationSnapshot],
                     today: String?, dailyInterfaceThreshold: Int64?, limit: Int = 8) -> UsageChartData {
        let interfaceValues: [UsageChartValue]
        if let interfaceUsage, interfaceUsage.day == today,
           interfaceUsage.uploadedBytes >= 0, interfaceUsage.downloadedBytes >= 0 {
            interfaceValues = [
                UsageChartValue(id: "uploaded", label: "上传", bytes: interfaceUsage.uploadedBytes),
                UsageChartValue(id: "downloaded", label: "下载", bytes: interfaceUsage.downloadedBytes)
            ]
        } else {
            interfaceValues = []
        }

        let applicationValues = applications.compactMap { application -> UsageChartValue? in
            guard application.usage.appKey == application.identity.key,
                  application.usage.day == today,
                  application.usage.uploadedBytes >= 0,
                  application.usage.downloadedBytes >= 0,
                  let bytes = UsageFormatter.total([
                    application.usage.uploadedBytes,
                    application.usage.downloadedBytes
                  ]), bytes > 0 else { return nil }
            return UsageChartValue(id: application.identity.key,
                                   label: application.identity.name,
                                   bytes: bytes)
        }
        .sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }

        return UsageChartData(interfaceValues: interfaceValues,
                              applicationValues: Array(applicationValues.prefix(max(0, limit))),
                              dailyInterfaceThreshold: dailyInterfaceThreshold,
                              applicationPie: UsagePieData.make(applicationValues))
    }
}
