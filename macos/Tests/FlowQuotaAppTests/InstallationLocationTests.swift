import Foundation
import Testing
@testable import FlowQuotaApp

struct InstallationLocationTests {
    @Test func recognizesSystemAndUserApplicationsDirectories() {
        let system = URL(fileURLWithPath: "/Applications/Flow Quota.app")
        let user = URL(fileURLWithPath: "/Users/example/Applications/Flow Quota.app")
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Users/example/Applications", isDirectory: true),
        ]

        #expect(InstallationLocation.isInApplications(bundleURL: system, applicationsDirectories: directories))
        #expect(InstallationLocation.isInApplications(bundleURL: user, applicationsDirectories: directories))
    }

    @Test func rejectsDownloadsAndDmgPaths() {
        let download = URL(fileURLWithPath: "/Users/example/Downloads/Flow Quota.app")
        let mounted = URL(fileURLWithPath: "/Volumes/Flow Quota 0.2.0/Flow Quota.app")
        let directories = [URL(fileURLWithPath: "/Applications", isDirectory: true)]

        #expect(!InstallationLocation.isInApplications(bundleURL: download, applicationsDirectories: directories))
        #expect(!InstallationLocation.isInApplications(bundleURL: mounted, applicationsDirectories: directories))
    }
}
