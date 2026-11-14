// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDirStatCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MacDirStatCore", targets: ["MacDirStatCore"])],
    targets: [
        .target(name: "MacDirStatCore", path: "MacDirStat/Core"),
        .testTarget(name: "MacDirStatCoreTests", dependencies: ["MacDirStatCore"], path: "Tests/MacDirStatCoreTests")
    ]
)
