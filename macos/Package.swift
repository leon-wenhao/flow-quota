// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlowQuota",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FlowQuotaCore", targets: ["FlowQuotaCore"]),
        .library(name: "FlowQuotaStore", targets: ["FlowQuotaStore"]),
        .library(name: "FlowQuotaPlatform", targets: ["FlowQuotaPlatform"]),
        .executable(name: "FlowQuota", targets: ["FlowQuotaApp"]),
        .executable(name: "FlowQuotaAgent", targets: ["FlowQuotaAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "FlowQuotaCore"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "FlowQuotaStore", dependencies: ["FlowQuotaCore", "CSQLite"]),
        .target(name: "FlowQuotaPlatform", dependencies: ["FlowQuotaCore"]),
        .executableTarget(name: "FlowQuotaAgent", dependencies: ["FlowQuotaCore", "FlowQuotaStore", "FlowQuotaPlatform"]),
        .executableTarget(name: "FlowQuotaApp", dependencies: ["FlowQuotaCore", "FlowQuotaPlatform",
            .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "FlowQuotaCoreTests", dependencies: ["FlowQuotaCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FlowQuotaStoreTests", dependencies: ["FlowQuotaStore", "FlowQuotaCore"]),
        .testTarget(name: "FlowQuotaPlatformTests", dependencies: ["FlowQuotaPlatform", "FlowQuotaCore"]),
        .testTarget(name: "FlowQuotaAgentTests", dependencies: ["FlowQuotaAgent", "FlowQuotaStore", "FlowQuotaCore"]),
        .testTarget(name: "FlowQuotaAppTests", dependencies: ["FlowQuotaApp", "FlowQuotaPlatform", "FlowQuotaCore"]),
    ]
)
