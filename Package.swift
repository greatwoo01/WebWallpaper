// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WebWallpaper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WebWallpaper",
            path: "Sources/WebWallpaper"
        )
    ]
)
