// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchBrowserCore",
    platforms: [
        .iOS(.v15),
        .watchOS(.v8),
        .macOS(.v13)
    ],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"])
    ],
    targets: [
        .target(name: "BrowserCore", path: "BrowserCore"),
        .testTarget(
            name: "BrowserCoreTests",
            dependencies: ["BrowserCore"],
            path: "BrowserCoreTests"
        )
    ]
)
