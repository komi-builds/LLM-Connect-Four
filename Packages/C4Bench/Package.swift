// swift-tools-version: 6.2
import PackageDescription

// The bench library has no MLX dependency, so `swift test` works here. The `c4bench`
// executable is an Xcode tool target (see project.yml) because it links C4MLX.
let package = Package(
    name: "C4Bench",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "C4Bench", targets: ["C4Bench"])
    ],
    dependencies: [
        .package(path: "../C4Core"),
        .package(path: "../C4AI"),
    ],
    targets: [
        .target(
            name: "C4Bench",
            dependencies: ["C4Core", "C4AI"],
            resources: [.copy("Resources/puzzles.json")]
        ),
        .testTarget(
            name: "C4BenchTests",
            dependencies: ["C4Bench"],
            resources: [.copy("Golden")]
        ),
    ]
)
