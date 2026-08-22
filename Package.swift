// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMonitor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentMonitorShared", targets: ["AgentMonitorShared"]),
        .executable(name: "AgentMonitorApp", targets: ["AgentMonitorApp"]),
        .executable(name: "agent-monitor-helper", targets: ["AgentMonitorHelper"])
    ],
    targets: [
        .target(name: "AgentMonitorShared"),
        .executableTarget(
            name: "AgentMonitorApp",
            dependencies: ["AgentMonitorShared"],
            exclude: ["Info.plist", "Assets.xcassets"]
        ),
        .executableTarget(name: "AgentMonitorHelper", dependencies: ["AgentMonitorShared"]),
        .testTarget(name: "AgentMonitorSharedTests", dependencies: ["AgentMonitorShared"]),
        .testTarget(name: "AgentMonitorHelperTests", dependencies: ["AgentMonitorHelper", "AgentMonitorShared"]),
        .testTarget(name: "AgentMonitorAppTests", dependencies: ["AgentMonitorApp", "AgentMonitorShared"])
    ]
)
