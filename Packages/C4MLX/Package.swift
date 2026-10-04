// swift-tools-version: 6.2
import PackageDescription

// Everything that touches MLX lives here, so API changes are contained in one place.
// Build with xcodebuild, not `swift build`: SwiftPM alone does not build MLX's Metal
// shader library.
let package = Package(
    name: "C4MLX",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "C4MLX", targets: ["C4MLX"])
    ],
    dependencies: [
        .package(path: "../C4Core"),
        .package(path: "../C4AI"),
        // FoundationModelsIntegration (default-on) needs the macOS 27 SDK; keep it off.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3"), traits: []),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "C4MLX",
            dependencies: [
                "C4Core",
                "C4AI",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .testTarget(name: "C4MLXTests", dependencies: ["C4MLX"]),
    ]
)
