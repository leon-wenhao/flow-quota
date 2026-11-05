import Foundation

extension StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sqlite(let code, let message): return "本地数据库错误（\(code)）：\(message)"
        case .rollbackFailed(let original, let rollback):
            return "数据库事务和回滚均失败。原错误：\(original)；回滚：\(rollback)。请停止写入并检查本地数据。"
        case .closed: return "本地数据库连接已关闭。"
        case .unsupportedSchema(let version):
            return "数据库版本 \(version) 不受此应用支持，请使用匹配版本；不能通过删除数据库恢复。"
        case .invalidIdentifier:
            return "本地应用身份无效，必须非空、不含 NUL 且采用 Unicode NFC。旧库身份异常需要明确修复，不能自动合并。"
        case .invalidDay(let day): return "无效的本地日期：\(day)。"
        case .invalidBytes: return "流量计数或预算金额无效。"
        case .overflow: return "流量累计超出整数范围，已拒绝本次写入。"
        case .unknownApplication: return "应用身份尚未注册，不能写入其账本。"
        case .missingRule: return "尚未找到该应用的额度规则。"
        case .staleRuleVersion: return "规则版本已变化，请重新获取当前规则。"
        case .quotaExceeded: return "剩余额度不足，无法发放新的流量预算。"
        case .invalidExpiry: return "预算有效期无效，必须在当前自然日内。"
        case .inactiveDay: return "预算不属于当前本地日期，不能继续消费。"
        case .unknownLease: return "未找到对应的持久化预算，不能释放额度。"
        case .leaseConflict: return "预算请求或结算内容与已保存记录冲突。"
        case .leaseInactive: return "预算已失效，未确认部分继续保守保留。"
        case .staleTrafficAlertPolicy: return "预警配置版本已变化，请重新获取当前配置。"
        case .trafficAlertConflict: return "预警事件标识与已保存的内容冲突。"
        case .unknownTrafficAlert: return "未找到对应的预警事件，无法确认通知调度。"
        case .configuration(let message): return "数据库配置或完整性检查失败：\(message)"
        }
    }
}
