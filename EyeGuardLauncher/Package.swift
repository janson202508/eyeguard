// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EyeGuardLauncher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "EyeGuardLauncher",
            path: "Sources/EyeGuardLauncher"
        )
    ]
)
