import Testing
@testable import FlowQuotaCore

@Test func gapsAreExplicitAndNeverTurnIntoInventedApplicationBytes() {
    #expect(TrafficMeasurementComparison(total: 790_343_680, sources: 775_772_869) == .unexplained(14_570_811))
    #expect(TrafficMeasurementComparison(total: 800, sources: 900) == .overlapping(100))
    #expect(TrafficMeasurementComparison(total: 800, sources: 800) == .equal)
    #expect(TrafficMeasurementComparison(total: 0, sources: 0) == .equal)
    #expect(TrafficMeasurementComparison(total: 800, sources: nil) == .unavailable)
    #expect(TrafficMeasurementComparison(total: nil, sources: 800) == .unavailable)
    #expect(TrafficMeasurementComparison(total: -1, sources: 1) == .unavailable)
    #expect(TrafficMeasurementComparison(total: .max, sources: 0) == .unexplained(.max))
    #expect(TrafficMeasurementComparison(total: 0, sources: .max) == .overlapping(.max))
}
