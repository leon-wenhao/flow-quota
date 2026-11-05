import Darwin
import Testing
@testable import FlowQuotaPlatform

private let birthPID: Int32 = 42
private let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
private let kernelSize = MemoryLayout<kinfo_proc>.size

private let validBSD: ProcessBirthReader.BSDQuery = { pid, info in
    info.pbi_pid = UInt32(pid)
    info.pbi_start_tvsec = 100
    info.pbi_start_tvusec = 123_456
    return (bsdSize, 0)
}
private let validKernel: ProcessBirthReader.KernelQuery = { pid, info in
    info.kp_proc.p_pid = pid
    info.kp_proc.p_un.__p_starttime = timeval(tv_sec: 100, tv_usec: 123_456)
    return (0, kernelSize)
}
private let noFallback: ProcessBirthReader.KernelQuery = { _, _ in
    Issue.record("Unexpected fallback for valid or non-permission BSD response")
    return (-1, 0)
}

@Test func bsdBirthUsesExistingTokenWithoutFallback() {
    let result = ProcessBirthReader(bsdQuery: validBSD, kernelQuery: noFallback).read(birthPID)
    #expect(result?.token == "100.123456")
    #expect(result?.timeInterval == 100.123456)
}

@Test(arguments: [EPERM, EACCES])
func rootMetadataPermissionDenialUsesPublicKernelExport(error: Int32) {
    let reader = ProcessBirthReader(bsdQuery: { _, _ in (0, error) }, kernelQuery: validKernel)
    let original = ProcessBirthReader(bsdQuery: validBSD, kernelQuery: noFallback).read(birthPID)
    #expect(reader.read(birthPID) == original)
}

@Test(arguments: [ESRCH, EINVAL, Int32(0)])
func exitedProcessAndOtherErrorsDoNotFallback(error: Int32) {
    let reader = ProcessBirthReader(bsdQuery: { _, _ in (0, error) }, kernelQuery: noFallback)
    #expect(reader.read(birthPID) == nil)
}

@Test func invalidAndPartialBSDMetadataDoesNotFallback() {
    let queries: [ProcessBirthReader.BSDQuery] = [
        { _, _ in (bsdSize - 1, EPERM) },
        { _, _ in (bsdSize + 1, EPERM) },
        { pid, info in _ = validBSD(pid, &info); info.pbi_pid += 1; return (bsdSize, 0) },
        { pid, info in _ = validBSD(pid, &info); info.pbi_start_tvsec = 0; return (bsdSize, 0) },
        { pid, info in _ = validBSD(pid, &info); info.pbi_start_tvsec = .max; return (bsdSize, 0) },
        { pid, info in _ = validBSD(pid, &info); info.pbi_start_tvusec = 1_000_000; return (bsdSize, 0) },
    ]
    for query in queries {
        #expect(ProcessBirthReader(bsdQuery: query, kernelQuery: noFallback).read(birthPID) == nil)
    }
}

@Test func failedTruncatedAndInvalidKernelMetadataIsRejected() {
    let queries: [ProcessBirthReader.KernelQuery] = [
        { pid, info in _ = validKernel(pid, &info); return (-1, kernelSize) },
        { _, _ in (0, 0) },
        { pid, info in _ = validKernel(pid, &info); return (0, kernelSize - 1) },
        { pid, info in _ = validKernel(pid, &info); return (0, kernelSize + 1) },
        { pid, info in _ = validKernel(pid, &info); info.kp_proc.p_pid += 1; return (0, kernelSize) },
        { pid, info in
            _ = validKernel(pid, &info)
            info.kp_proc.p_un.__p_starttime.tv_sec = 0
            return (0, kernelSize)
        },
        { pid, info in
            _ = validKernel(pid, &info)
            info.kp_proc.p_un.__p_starttime.tv_usec = -1
            return (0, kernelSize)
        },
        { pid, info in
            _ = validKernel(pid, &info)
            info.kp_proc.p_un.__p_starttime.tv_usec = 1_000_000
            return (0, kernelSize)
        },
    ]
    for query in queries {
        let reader = ProcessBirthReader(bsdQuery: { _, _ in (0, EPERM) }, kernelQuery: query)
        #expect(reader.read(birthPID) == nil)
    }
}

@Test func invalidPIDsNeverInvokeEitherMetadataAPI() {
    let reader = ProcessBirthReader(bsdQuery: { _, _ in
        Issue.record("Invalid PID reached BSD query")
        return (0, EPERM)
    }, kernelQuery: noFallback)
    #expect(reader.read(0) == nil)
    #expect(reader.read(-1) == nil)
}
