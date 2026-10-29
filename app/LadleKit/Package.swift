// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LadleKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LadleKit", targets: ["LadleKit"]),
    ],
    targets: [
        .target(name: "LadleKit", path: "Sources/LadleKit"),
        .testTarget(name: "LadleKitTests", dependencies: ["LadleKit"], path: "Tests/LadleKitTests"),
    ]
)
