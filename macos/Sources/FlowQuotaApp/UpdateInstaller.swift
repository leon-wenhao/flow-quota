import AppKit
import CryptoKit
import Foundation

struct UpdateInstaller {
    static let maxPackageBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let chunkSize = 1024 * 1024

    @MainActor
    static func downloadAndOpen(_ release: UpdateRelease) async throws -> URL {
        guard let package = release.package else {
            throw UpdateInstallError.packageMetadataUnavailable
        }
        try package.validate()
        let directory = try updateDirectory()
        let destination = directory.appendingPathComponent(package.fileName, isDirectory: false)
        let temporary = directory.appendingPathComponent(".downloading-\(UUID().uuidString).dmg", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var request = URLRequest(url: package.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15 * 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (downloadedURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateInstallError.httpStatus(status)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: temporary)
        try verifyPackage(at: temporary, package: package)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        guard NSWorkspace.shared.open(destination) else {
            throw UpdateInstallError.openFailed
        }
        return destination
    }

    static func verifyPackage(at url: URL, package: UpdatePackage) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value == package.size else {
            throw UpdateInstallError.sizeMismatch
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var bytesRead: Int64 = 0
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            bytesRead += Int64(data.count)
            guard bytesRead <= maxPackageBytes else { throw UpdateInstallError.sizeMismatch }
            digest.update(data: data)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard bytesRead == package.size else { throw UpdateInstallError.sizeMismatch }
        guard actual == package.sha256 else { throw UpdateInstallError.digestMismatch }
    }

    private static func updateDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let directory = base.appendingPathComponent("Flow Quota/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }
}

enum UpdateInstallError: Error, LocalizedError, Equatable, Sendable {
    case packageMetadataUnavailable
    case httpStatus(Int)
    case sizeMismatch
    case digestMismatch
    case openFailed

    var errorDescription: String? {
        switch self {
        case .packageMetadataUnavailable: return "更新清单没有提供当前架构的安装包信息。"
        case .httpStatus(let status): return "下载更新失败（HTTP \(status)）。"
        case .sizeMismatch: return "下载包大小与更新清单不一致。"
        case .digestMismatch: return "下载包 SHA-256 校验失败。"
        case .openFailed: return "更新包已下载，但无法打开 DMG。"
        }
    }
}
