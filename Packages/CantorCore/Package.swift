// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CantorCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CantorCore", targets: ["CantorCore"])],
    targets: [
        .target(name: "CantorCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CantorCoreTests", dependencies: ["CantorCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
