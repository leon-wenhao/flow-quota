import Darwin
import Foundation

/// Both public APIs return the same microsecond birth stamp. Keeping one token
/// format avoids a new baseline merely because access to one API changes.
struct ProcessBirthStamp: Equatable, Sendable {
    let seconds: Int64
    let microseconds: Int32

    init?(seconds: Int64, microseconds: Int32) {
        guard seconds > 0, (0..<1_000_000).contains(microseconds) else { return nil }
        self.seconds = seconds
        self.microseconds = microseconds
    }

    var token: String { "\(seconds).\(microseconds)" }
    var timeInterval: TimeInterval { Double(seconds) + Double(microseconds) / 1_000_000 }
}

/// A root-owned proxy may deny PROC_PIDTBSDINFO while allowing the documented
/// KERN_PROC_PID export. Neither path elevates privileges or reads traffic.
struct ProcessBirthReader: Sendable {
    typealias BSDQuery = @Sendable (Int32, inout proc_bsdinfo) -> (count: Int32, error: Int32)
    typealias KernelQuery = @Sendable (Int32, inout kinfo_proc) -> (status: Int32, length: Int)
    private let bsdQuery: BSDQuery
    private let kernelQuery: KernelQuery

    init(bsdQuery: @escaping BSDQuery = Self.queryBSD,
         kernelQuery: @escaping KernelQuery = Self.queryKernel) {
        self.bsdQuery = bsdQuery
        self.kernelQuery = kernelQuery
    }

    func read(_ pid: Int32) -> ProcessBirthStamp? {
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let result = bsdQuery(pid, &bsd)
        if result.count == MemoryLayout<proc_bsdinfo>.size {
            guard bsd.pbi_pid == UInt32(pid), bsd.pbi_start_tvsec <= Int64.max,
                  bsd.pbi_start_tvusec < 1_000_000 else { return nil }
            return ProcessBirthStamp(seconds: Int64(bsd.pbi_start_tvsec), microseconds: Int32(bsd.pbi_start_tvusec))
        }
        // Do not reinterpret an exited process or a malformed response as a
        // permissions issue. Only the narrow access-denied case uses sysctl.
        guard result.count <= 0, result.error == EPERM || result.error == EACCES else { return nil }
        var kernel = kinfo_proc()
        let fallback = kernelQuery(pid, &kernel)
        guard fallback.status == 0, fallback.length == MemoryLayout<kinfo_proc>.size,
              kernel.kp_proc.p_pid == pid else { return nil }
        let start = kernel.kp_proc.p_un.__p_starttime
        return ProcessBirthStamp(seconds: Int64(start.tv_sec), microseconds: start.tv_usec)
    }

    private static func queryBSD(_ pid: Int32, _ info: inout proc_bsdinfo) -> (count: Int32, error: Int32) {
        errno = 0
        let count = withUnsafeMutableBytes(of: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0.baseAddress, Int32($0.count))
        }
        return (count, errno)
    }

    private static func queryKernel(_ pid: Int32, _ info: inout kinfo_proc) -> (status: Int32, length: Int) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var length = MemoryLayout<kinfo_proc>.size
        let status = mib.withUnsafeMutableBufferPointer { query in
            withUnsafeMutablePointer(to: &info) {
                sysctl(query.baseAddress, UInt32(query.count), $0, &length, nil, 0)
            }
        }
        return (status, length)
    }
}
