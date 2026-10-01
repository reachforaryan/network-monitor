// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetworkMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MonitorCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "NetworkMonitorApp",
            dependencies: ["MonitorCore"]
        ),
        .testTarget(
            name: "MonitorCoreTests",
            dependencies: ["MonitorCore"]
        ),
    ]
)
