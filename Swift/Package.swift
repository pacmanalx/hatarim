// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HaTarim",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HaTarim",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
