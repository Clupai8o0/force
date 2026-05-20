// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Force",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Force",
            path: "Sources/Force",
            resources: [
                .process("Resources/Fonts")
            ]
        )
    ]
)
