import Darwin
import Foundation

/// NET_RT_IFLIST2 is a stream of variable-length routing messages. Load only
/// after validating boundaries; Data and subsequent messages need not be aligned.
enum InterfaceTrafficMessages {
    static func parse(_ data: Data, interfaceIndex: UInt32) throws -> InterfaceCounterSnapshot {
        guard interfaceIndex > 0, interfaceIndex <= UInt16.max else {
            throw InterfaceCounterError.invalidInterfaceIndex(interfaceIndex)
        }
        guard data.count <= InterfaceSysctlReader.maximumBufferBytes else {
            throw InterfaceCounterError.bufferLimitExceeded
        }
        return try data.withUnsafeBytes { bytes in
            var offset = 0
            var result: InterfaceCounterSnapshot?
            while offset < bytes.count {
                // All route messages start with length (u_short), version and type.
                guard bytes.count - offset >= 4 else { throw InterfaceCounterError.malformedResponse }
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= bytes.count - offset,
                      bytes[offset + 2] == UInt8(RTM_VERSION) else {
                    throw InterfaceCounterError.malformedResponse
                }
                if bytes[offset + 3] == UInt8(RTM_IFINFO2) {
                    guard length >= MemoryLayout<if_msghdr2>.size else {
                        throw InterfaceCounterError.malformedResponse
                    }
                    let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(header.ifm_index) == interfaceIndex {
                        guard result == nil else { throw InterfaceCounterError.duplicateInterface(interfaceIndex) }
                        let requiredFlags = Int32(IFF_UP | IFF_RUNNING)
                        let excludedTypes = [UInt8(IFT_LOOP), UInt8(IFT_GIF), UInt8(IFT_STF)]
                        guard header.ifm_flags & requiredFlags == requiredFlags,
                              header.ifm_flags & Int32(IFF_LOOPBACK) == 0,
                              !excludedTypes.contains(header.ifm_data.ifi_type) else {
                            throw InterfaceCounterError.interfaceUnavailable(interfaceIndex)
                        }
                        result = InterfaceCounterSnapshot(interfaceIndex: interfaceIndex,
                            uploadedBytes: header.ifm_data.ifi_obytes,
                            downloadedBytes: header.ifm_data.ifi_ibytes)
                    }
                }
                offset += length
            }
            guard let result else { throw InterfaceCounterError.interfaceUnavailable(interfaceIndex) }
            return result
        }
    }
}
