import Foundation

enum InstallationLocation {
    static var isInApplications: Bool {
        isInApplications(bundleURL: Bundle.main.bundleURL)
    }

    static func isInApplications(bundleURL: URL, applicationsDirectories: [URL] = defaultDirectories) -> Bool {
        let bundlePath = bundleURL.standardizedFileURL.path
        return applicationsDirectories.contains { directory in
            let directoryPath = directory.standardizedFileURL.path
            return bundlePath == directoryPath || bundlePath.hasPrefix(directoryPath + "/")
        }
    }

    private static var defaultDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }
}
