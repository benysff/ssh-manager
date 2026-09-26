// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SSHManager",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SSHManager",
            path: "Sources/SSHManager"
        )
    ]
)
