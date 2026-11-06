/// Compares independently observed scopes without inventing an application owner.
/// Positive differences include unrecognized traffic, timing and protocol overhead;
/// a negative difference indicates overlap or different observation intervals.
public enum TrafficMeasurementComparison: Equatable, Sendable {
    case unavailable
    case equal
    case unexplained(Int64)
    case overlapping(Int64)

    public init(total: Int64?, sources: Int64?) {
        guard let total, let sources, total >= 0, sources >= 0 else {
            self = .unavailable
            return
        }
        if total > sources { self = .unexplained(total - sources) }
        else if sources > total { self = .overlapping(sources - total) }
        else { self = .equal }
    }
}
