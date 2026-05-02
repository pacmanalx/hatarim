// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MonitorINO2",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MonitorINO2",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
