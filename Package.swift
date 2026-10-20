// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowArrange",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WindowArrange", targets: ["WindowArrange"])],
    targets: [
        .target(name: "ArrangementCore"),
        .executableTarget(name: "WindowArrange", dependencies: ["ArrangementCore"]),
        .testTarget(name: "ArrangementCoreTests", dependencies: ["ArrangementCore"]),
        .testTarget(name: "WindowArrangeTests", dependencies: ["WindowArrange"])
    ],
    swiftLanguageModes: [.v5]
)
