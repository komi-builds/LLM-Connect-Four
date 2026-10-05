// swift-tools-version: 6.2
import PackageDescription

// C4AI has no MLX dependency, so `swift test` works here. Everything that touches MLX
// lives in the C4MLX package.
let package = Package(
  name: "C4AI",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "C4AI", targets: ["C4AI"])
  ],
  dependencies: [
    .package(path: "../C4Core")
  ],
  targets: [
    .target(
      name: "C4AI",
      dependencies: ["C4Core"],
      resources: [.copy("Resources/models.json"), .copy("Resources/prompts")]
    ),
    .testTarget(
      name: "C4AITests",
      dependencies: ["C4AI"],
      resources: [.copy("Golden")]
    ),
  ]
)
