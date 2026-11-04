import Darwin
import Foundation

/// Own the filesystem boundary before SQLite opens any file. Creation attributes
/// and umask do not secure existing/restored directories, and symlinks are rejected.
public enum ServiceStorage {
    public static func prepareDatabase(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try secure(directory, directory: true)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try secure(URL(fileURLWithPath: url.path + suffix), directory: false)
        }
    }

    private static func secure(_ url: URL, directory: Bool) throws {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0)
        let descriptor = open(url.path, flags)
        if descriptor < 0 {
            if !directory && errno == ENOENT { return }
            throw PlatformError.unavailable("无法安全打开本地数据路径，可能包含符号链接或权限不正确。")
        }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_uid == getuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else {
            throw PlatformError.unavailable("本地数据路径类型或所有者不正确，请检查 FlowQuota 数据目录。")
        }
        let mode: mode_t = directory ? 0o700 : 0o600
        guard fchmod(descriptor, mode) == 0 else {
            throw PlatformError.unavailable("无法将本地数据权限收紧到当前用户。")
        }
    }
}
