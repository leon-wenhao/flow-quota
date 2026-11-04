import Foundation
import FlowQuotaCore

/// The portable JSON schema deliberately uses strings for every byte field (>2^53 safe).
struct QuotaVectors: Decodable {
    let schemaVersion: Int
    let conversions: [Conversion]
    let days: [Day]
    let evaluations: [Evaluation]
    let notifications: [Notification]
    let budgets: [Budget]

    struct Conversion: Decodable {
        let id: String
        let input: String
        let unit: DecimalByteUnit
        let expectedBytes: String?
        let expectedError: String?
    }

    struct Day: Decodable {
        let id: String
        let instant: String
        let timeZone: String
        let expectedDay: String
    }

    struct Evaluation: Decodable {
        let id: String
        let uploadedBytes: String?
        let downloadedBytes: String?
        let limitBytes: String?
        let warningPercent: Int
        let network: NetworkState
        let hasRule: Bool
        let expectedStatus: String?
        let expectedRemainingBytes: String?
        let expectedThresholdBytes: String?
        let expectedError: String?
    }

    struct Notification: Decodable {
        let id: String
        let appKey: String
        let day: String
        let ruleVersion: Int64
        let limitBytes: String?
        let warningPercent: Int
        let uploadedBytes: String
        let downloadedBytes: String
        let network: NetworkState
        let delivered: Set<QuotaNotificationKey>
        let expectedNotification: QuotaNotificationKind?
    }

    struct Budget: Decodable {
        let id: String
        let limitBytes: String?
        let usedBytes: String
        let steps: [BudgetStep]
    }

    struct BudgetStep: Decodable {
        let operation: String
        let token: String?
        let bytes: String?
        let expectedGrantedBytes: String?
        let limitBytes: String?
        let version: Int64?
        let expectedUsedBytes: String
        let expectedReservedBytes: String
        let expectedAvailableBytes: String
    }
}
