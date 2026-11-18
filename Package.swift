// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Livella",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Livella",
            path: "Sources/Livella",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
