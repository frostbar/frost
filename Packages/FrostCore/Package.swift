// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrostCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "FrostCore", targets: ["FrostCore"])],
    targets: [
        .target(name: "FrostCore"),
        .testTarget(name: "FrostCoreTests", dependencies: ["FrostCore"]),
    ]
)
