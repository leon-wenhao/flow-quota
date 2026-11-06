import Foundation
import Testing
@testable import FlowQuotaApp

struct UpdateInstallerTests {
    @Test func verifiesDownloadedPackageSizeAndDigest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-quota-update-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("FlowQuota.dmg")
        try Data("test".utf8).write(to: file)
        let package = UpdatePackage(
            format: "dmg",
            fileName: "FlowQuota.dmg",
            url: URL(string: "https://example.com/FlowQuota.dmg")!,
            size: 4,
            sha256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        )

        try UpdateInstaller.verifyPackage(at: file, package: package)
    }

    @Test func rejectsDownloadedPackageWithWrongDigest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-quota-update-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("FlowQuota.dmg")
        try Data("test".utf8).write(to: file)
        let package = UpdatePackage(
            format: "dmg",
            fileName: "FlowQuota.dmg",
            url: URL(string: "https://example.com/FlowQuota.dmg")!,
            size: 4,
            sha256: String(repeating: "0", count: 64)
        )

        #expect(throws: UpdateInstallError.digestMismatch) {
            try UpdateInstaller.verifyPackage(at: file, package: package)
        }
    }
}
