import Darwin
import Foundation
import Testing
@testable import FlowQuotaPlatform

@Test func restoresPrivatePermissionsForExistingDatabaseDirectory() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let database = folder.appendingPathComponent("quota.sqlite")
    try Data().write(to: database)
    #expect(chmod(folder.path, 0o777) == 0)
    #expect(chmod(database.path, 0o666) == 0)
    try ServiceStorage.prepareDatabase(at: database)
    var directoryInfo = stat()
    var fileInfo = stat()
    #expect(lstat(folder.path, &directoryInfo) == 0)
    #expect(lstat(database.path, &fileInfo) == 0)
    #expect(directoryInfo.st_mode & 0o777 == 0o700)
    #expect(fileInfo.st_mode & 0o777 == 0o600)
}

@Test func refusesSymlinkDatabaseWithoutTouchingTarget() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("unrelated")
    try Data("unrelated".utf8).write(to: target)
    let database = folder.appendingPathComponent("quota.sqlite")
    try FileManager.default.createSymbolicLink(at: database, withDestinationURL: target)
    #expect(throws: (any Error).self) { try ServiceStorage.prepareDatabase(at: database) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "unrelated")
}

@Test func refusesSymlinkDirectory() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let link = folder.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: (any Error).self) {
        try ServiceStorage.prepareDatabase(at: link.appendingPathComponent("quota.sqlite"))
    }
}
