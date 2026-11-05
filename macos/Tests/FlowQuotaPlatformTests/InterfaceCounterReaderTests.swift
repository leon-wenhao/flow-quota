import Darwin
import Foundation
import Testing
@testable import FlowQuotaPlatform

private func routeMessage(index: UInt16 = 4, up: UInt64 = 10, down: UInt64 = 20,
                          flags: Int32 = Int32(IFF_UP | IFF_RUNNING),
                          interfaceType: UInt8 = UInt8(IFT_ETHER)) -> Data {
    var header = if_msghdr2()
    header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
    header.ifm_version = UInt8(RTM_VERSION)
    header.ifm_type = UInt8(RTM_IFINFO2)
    header.ifm_index = index
    header.ifm_flags = flags
    header.ifm_data.ifi_type = interfaceType
    header.ifm_data.ifi_obytes = up
    header.ifm_data.ifi_ibytes = down
    return withUnsafeBytes(of: &header) { Data($0) }
}

/// Only scripted memory copies: these tests never call the operating system reader.
private final class ScriptedSysctl: @unchecked Sendable {
    struct Reply: Sendable {
        let length: Int
        var error: Int32 = 0
        var payload = Data()
    }
    private let lock = NSLock()
    private var replies: [Reply]
    private var requests: [([Int32], Bool)] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func call(_ mib: [Int32], _ buffer: UnsafeMutableRawPointer?, _ length: inout Int) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        requests.append((mib, buffer == nil))
        guard !replies.isEmpty else { return EIO }
        let reply = replies.removeFirst()
        if let buffer, !reply.payload.isEmpty {
            reply.payload.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self),
                                    count: min(length, reply.payload.count))
        }
        length = reply.length
        return reply.error
    }

    var calls: [([Int32], Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

@Suite struct InterfaceCounterReaderTests {
    @Test func selectedMIBUses64BitCountersAndExactIndex() throws {
        let large = UInt64(UInt32.max) + 10_000
        let bytes = routeMessage(up: large, down: large + 1)
        let mock = ScriptedSysctl([.init(length: bytes.count), .init(length: bytes.count, payload: bytes)])
        let counter = SystemInterfaceTrafficCounter(reader: InterfaceSysctlReader(call: mock.call))
        let result = try counter.read(interfaceIndex: 4)
        #expect(result == InterfaceCounterSnapshot(interfaceIndex: 4, uploadedBytes: large,
                                                  downloadedBytes: large + 1))
        #expect(mock.calls.count == 2)
        for (mib, _) in mock.calls { #expect(mib == [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 4]) }
        #expect(mock.calls[0].1 && !mock.calls[1].1)
    }

    @Test func parsesUnalignedMessagesAndNeverSumsOtherIndexes() throws {
        var length: UInt16 = 5
        var unknown = withUnsafeBytes(of: &length) { Data($0) }
        unknown.append(contentsOf: [UInt8(RTM_VERSION), 0x7f, 0])
        let bytes = unknown + routeMessage(index: 8, up: 999) + routeMessage(up: 123)
        #expect(try InterfaceTrafficMessages.parse(bytes, interfaceIndex: 4).uploadedBytes == 123)
    }

    @Test(arguments: [UInt32(0), UInt32(UInt16.max) + 1, UInt32.max])
    func invalidIndexesNeverRequestAllInterfaces(index: UInt32) {
        let mock = ScriptedSysctl([])
        let reader = InterfaceSysctlReader(call: mock.call)
        #expect(throws: InterfaceCounterError.invalidInterfaceIndex(index)) { try reader.read(interfaceIndex: index) }
        #expect(mock.calls.isEmpty)
    }

    @Test func missingAndDuplicateInterfacesFailClosed() {
        #expect(throws: InterfaceCounterError.interfaceUnavailable(4)) {
            try InterfaceTrafficMessages.parse(routeMessage(index: 8), interfaceIndex: 4)
        }
        #expect(throws: InterfaceCounterError.duplicateInterface(4)) {
            try InterfaceTrafficMessages.parse(routeMessage() + routeMessage(), interfaceIndex: 4)
        }
        #expect(throws: InterfaceCounterError.interfaceUnavailable(4)) {
            try InterfaceTrafficMessages.parse(Data(), interfaceIndex: 4)
        }
    }

    @Test(arguments: [Int32(0), Int32(IFF_UP), Int32(IFF_RUNNING), Int32(IFF_UP | IFF_RUNNING | IFF_LOOPBACK)])
    func downUnallocatedOrLoopbackInterfaceIsUnavailable(flags: Int32) {
        #expect(throws: InterfaceCounterError.interfaceUnavailable(4)) {
            try InterfaceTrafficMessages.parse(routeMessage(flags: flags), interfaceIndex: 4)
        }
    }

    @Test(arguments: [UInt8(IFT_LOOP), UInt8(IFT_GIF), UInt8(IFT_STF)])
    func explicitlyVirtualInterfaceTypesAreUnavailable(type: UInt8) {
        #expect(throws: InterfaceCounterError.interfaceUnavailable(4)) {
            try InterfaceTrafficMessages.parse(routeMessage(interfaceType: type), interfaceIndex: 4)
        }
    }

    @Test func pppIsNotArbitrarilyExcluded() throws {
        #expect(try InterfaceTrafficMessages.parse(routeMessage(interfaceType: UInt8(IFT_PPP)),
                                                  interfaceIndex: 4).interfaceIndex == 4)
    }

    @Test func rejectsTruncationBadLengthsVersionsAndTrailingPartialMessage() {
        let good = routeMessage()
        var zeroLength = good
        zeroLength[0] = 0
        zeroLength[1] = 0
        var tooSmall = good
        tooSmall[0] = 3
        tooSmall[1] = 0
        var truncatedHeader = good
        truncatedHeader[0] = 4
        truncatedHeader[1] = 0
        var wrongVersion = good
        wrongVersion[2] = UInt8(RTM_VERSION + 1)
        let malformed = [Data([1, 0, 5]), Data(good.dropLast()), zeroLength, tooSmall,
                         truncatedHeader, wrongVersion, good + Data([0])]
        for bytes in malformed {
            #expect(throws: InterfaceCounterError.malformedResponse) {
                try InterfaceTrafficMessages.parse(bytes, interfaceIndex: 4)
            }
        }
    }

    @Test func growthRetriesDiscardPartialResponseAndRequerySize() throws {
        let good = routeMessage()
        let mock = ScriptedSysctl([
            .init(length: 4), .init(length: 4, error: ENOMEM, payload: Data([1, 2, 3, 4])),
            .init(length: good.count), .init(length: good.count, payload: good)
        ])
        let counter = SystemInterfaceTrafficCounter(reader: InterfaceSysctlReader(call: mock.call))
        #expect(try counter.read(interfaceIndex: 4).uploadedBytes == 10)
        #expect(mock.calls.count == 4)
    }

    @Test func repeatedGrowthHasBoundedRetries() {
        let replies: [ScriptedSysctl.Reply] = (0..<InterfaceSysctlReader.maximumAttempts).flatMap { _ in
            [.init(length: 4), .init(length: 4, error: ENOMEM)]
        }
        let mock = ScriptedSysctl(replies)
        #expect(throws: InterfaceCounterError.systemCallFailed(ENOMEM)) {
            try InterfaceSysctlReader(call: mock.call).read(interfaceIndex: 4)
        }
        #expect(mock.calls.count == InterfaceSysctlReader.maximumAttempts * 2)
    }

    @Test(arguments: [-1, InterfaceSysctlReader.maximumBufferBytes + 1])
    func allocationCapRejectsUntrustedSizes(size: Int) {
        let mock = ScriptedSysctl([.init(length: size)])
        #expect(throws: InterfaceCounterError.bufferLimitExceeded) {
            try InterfaceSysctlReader(call: mock.call).read(interfaceIndex: 4)
        }
        #expect(mock.calls.count == 1)
    }

    @Test func parserAlsoRejectsOversizedResponses() {
        #expect(throws: InterfaceCounterError.bufferLimitExceeded) {
            try InterfaceTrafficMessages.parse(Data(count: InterfaceSysctlReader.maximumBufferBytes + 1),
                                                interfaceIndex: 4)
        }
    }

    @Test func syscallErrorsZeroSizeAndInvalidWrittenLengthsAreVisible() {
        for replies: [ScriptedSysctl.Reply] in [
            [.init(length: 0, error: EACCES)],
            [.init(length: 4), .init(length: 0, error: EIO)]
        ] {
            let mock = ScriptedSysctl(replies)
            #expect(throws: InterfaceCounterError.self) {
                try InterfaceSysctlReader(call: mock.call).read(interfaceIndex: 4)
            }
        }
        let empty = ScriptedSysctl([.init(length: 0)])
        #expect(throws: InterfaceCounterError.interfaceUnavailable(4)) {
            try InterfaceSysctlReader(call: empty.call).read(interfaceIndex: 4)
        }
        for written in [-1, 0, 5] {
            let mock = ScriptedSysctl([.init(length: 4), .init(length: written)])
            #expect(throws: InterfaceCounterError.malformedResponse) {
                try InterfaceSysctlReader(call: mock.call).read(interfaceIndex: 4)
            }
        }
    }
}
