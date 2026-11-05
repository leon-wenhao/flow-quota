import Darwin
import Foundation

/// Returns an errno value (zero on success), captured immediately at the call.
/// Injected calls are synchronous and must not retain the buffer pointer.
typealias InterfaceSysctlCall = @Sendable ([Int32], UnsafeMutableRawPointer?, inout Int) -> Int32

struct InterfaceSysctlReader: Sendable {
    // An index-filtered interface response should be small. Bound allocation even
    // if a size query reports corrupt or unexpectedly large data.
    static let maximumBufferBytes = 1_048_576
    static let maximumAttempts = 3
    private let call: InterfaceSysctlCall

    init(call: @escaping InterfaceSysctlCall = { name, buffer, length in
        var mib = name
        return sysctl(&mib, UInt32(mib.count), buffer, &length, nil, 0) == 0 ? 0 : errno
    }) {
        self.call = call
    }

    func read(interfaceIndex: UInt32) throws -> Data {
        // if_msghdr2 carries a u_short index; reject truncation and index zero
        // (which requests all interfaces instead of the selected physical one).
        guard interfaceIndex > 0, interfaceIndex <= UInt16.max else {
            throw InterfaceCounterError.invalidInterfaceIndex(interfaceIndex)
        }
        let mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(interfaceIndex)]
        for _ in 0..<Self.maximumAttempts {
            var required = 0
            let sizeError = call(mib, nil, &required)
            guard sizeError == 0 else { throw InterfaceCounterError.systemCallFailed(sizeError) }
            guard required >= 0, required <= Self.maximumBufferBytes else {
                throw InterfaceCounterError.bufferLimitExceeded
            }
            guard required > 0 else { throw InterfaceCounterError.interfaceUnavailable(interfaceIndex) }
            var data = Data(count: required)
            var written = required
            let readError = data.withUnsafeMutableBytes { bytes in
                call(mib, bytes.baseAddress, &written)
            }
            // Interface/address lists may grow between size query and read. Never
            // parse partial ENOMEM output; re-query with a bounded retry budget.
            if readError == ENOMEM { continue }
            guard readError == 0 else { throw InterfaceCounterError.systemCallFailed(readError) }
            guard written > 0, written <= required else { throw InterfaceCounterError.malformedResponse }
            data.count = written
            return data
        }
        throw InterfaceCounterError.systemCallFailed(ENOMEM)
    }
}
