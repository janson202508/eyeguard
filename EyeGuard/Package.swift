// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EyeGuard",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "EyeGuard",
            path: "Sources/EyeGuard"
        )
    ]
)
