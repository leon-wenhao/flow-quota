import FlowQuotaCore

/// Editor state uses the same decimal parser as existing application quotas.
struct TrafficAlertDraft {
    var dailyEnabled: Bool
    var interfaceEnabled: Bool
    var applicationEnabled: Bool
    var dailyMB: String
    var interfaceMB: String
    var applicationMB: String
    var windowMinutes: Int
    var cooldownMinutes: Int
    let original: TrafficAlertPolicy

    init(_ policy: TrafficAlertPolicy) {
        original = policy
        dailyEnabled = policy.dailyInterfaceBytes != nil
        interfaceEnabled = policy.interfaceBurstBytes != nil
        applicationEnabled = policy.applicationBurstBytes != nil
        dailyMB = policy.dailyInterfaceBytes.map { QuotaInput.text($0, unit: .megabytes) } ?? "1000"
        interfaceMB = policy.interfaceBurstBytes.map { QuotaInput.text($0, unit: .megabytes) } ?? "200"
        applicationMB = policy.applicationBurstBytes.map { QuotaInput.text($0, unit: .megabytes) } ?? "200"
        windowMinutes = policy.windowSeconds / 60
        cooldownMinutes = policy.cooldownSeconds / 60
    }

    var policy: TrafficAlertPolicy? {
        let daily = dailyEnabled ? QuotaInput.bytes(dailyMB, unit: .megabytes) : nil
        let link = interfaceEnabled ? QuotaInput.bytes(interfaceMB, unit: .megabytes) : nil
        let app = applicationEnabled ? QuotaInput.bytes(applicationMB, unit: .megabytes) : nil
        guard original.version < Int64.max, !dailyEnabled || daily != nil,
              !interfaceEnabled || link != nil, !applicationEnabled || app != nil else { return nil }
        return try? TrafficAlertPolicy(dailyInterfaceBytes: daily, interfaceBurstBytes: link,
            applicationBurstBytes: app, windowSeconds: windowMinutes * 60,
            cooldownSeconds: cooldownMinutes * 60, version: original.version + 1)
    }
}
