// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LexiWatch",
    platforms: [.macOS(.v14), .watchOS(.v11)],
    products: [
        .library(name: "DictionaryCore", targets: ["DictionaryCore"])
    ],
    targets: [
        .target(
            name: "DictionaryCore",
            path: "DictionaryCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "DictionaryCoreTests",
            dependencies: ["DictionaryCore"],
            path: "DictionaryCoreTests"
        )
    ]
)
