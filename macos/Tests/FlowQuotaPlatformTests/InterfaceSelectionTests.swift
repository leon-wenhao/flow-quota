import Network
import Testing
@testable import FlowQuotaPlatform

@Suite struct InterfaceSelectionTests {
    @Test func onlyUsedPhysicalTypesQualifyAndIndexesAreDeduplicated() {
        let interfaces: [(index: Int, type: NWInterface.InterfaceType)] = [
            (4, .wifi), (4, .wifi), (5, .wiredEthernet), (6, .cellular),
            (7, .other), (8, .loopback), (0, .wifi), (-1, .wifi)
        ]
        let indexes = eligiblePhysicalInterfaceIndexes(interfaces) { $0 == .wifi || $0 == .other }
        #expect(indexes == [4])
        let observation = NetworkObservation(state: .expensive, message: "", interfaceIndexes: indexes)
        #expect(observation.interfaceSelection == .selected(4))
    }

    @Test func noPhysicalAndAmbiguousSelectionsHaveExplicitReasons() {
        let noUsedPhysical = eligiblePhysicalInterfaceIndexes([(4, .wifi), (9, .other)]) { $0 == .other }
        #expect(noUsedPhysical.isEmpty)
        let none = NetworkObservation(state: .expensive, message: "", interfaceIndexes: noUsedPhysical)
        #expect(none.interfaceSelection == .unavailable(.noPhysicalInterface))
        let candidates = eligiblePhysicalInterfaceIndexes([(4, .wifi), (5, .wifi)]) { _ in true }
        let ambiguous = NetworkObservation(state: .hotspot, message: "", interfaceIndexes: candidates)
        #expect(ambiguous.interfaceSelection == .unavailable(.ambiguousPhysicalInterfaces))
        #expect(!InterfaceSelectionUnavailableReason.ambiguousPhysicalInterfaces.message.isEmpty)
    }

    @Test func everySupportedPhysicalTypeCanBeSelected() {
        for type: NWInterface.InterfaceType in [.wifi, .wiredEthernet, .cellular] {
            #expect(eligiblePhysicalInterfaceIndexes([(4, type)]) { $0 == type } == [4])
        }
    }

    @Test func manualMarkKeepsTheSamePhysicalSelectionAndUnavailableClearsIt() throws {
        var state = NetworkTrackingState()
        #expect(state.snapshot.interfaceSelection == .unavailable(.networkUnavailable))
        state.update(isAvailable: true, isExpensive: true, interfaceIndexes: [4])
        #expect(state.snapshot.interfaceSelection == .selected(4))
        try state.markCurrentPath(true)
        #expect(state.snapshot.interfaceIndexes == [4])
        #expect(state.snapshot.interfaceSelection == .selected(4))
        state.update(isAvailable: false, isExpensive: true, interfaceIndexes: [4])
        #expect(state.snapshot.interfaceIndexes.isEmpty)
        #expect(state.snapshot.interfaceSelection == .unavailable(.networkUnavailable))
    }
}
