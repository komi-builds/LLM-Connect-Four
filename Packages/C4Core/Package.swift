// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "C4Core",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "C4Core", targets: ["C4Core"])
  ],
  targets: [
    .target(name: "C4Core"),
    .testTarget(name: "C4CoreTests", dependencies: ["C4Core"]),
  ]
)
