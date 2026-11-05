import Foundation
import Darwin

/// nettop block-buffers stdout when attached to a pipe. A local pseudo-terminal
/// keeps its documented CSV logging mode line-buffered without private APIs or a shell.
struct SamplerTerminal {
    let reader: FileHandle
    let writer: FileHandle

    init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PlatformError.unavailable("无法创建系统采样输出终端。")
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        reader = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        writer = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
    }
}
