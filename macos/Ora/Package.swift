// swift-tools-version: 5.10
// Ora — local real-time speech translator, native Swift + MLX.
// Consumes speech-swift (VAD + on-device ASR) and mlx-swift-lm (on-device
// translator LLMs across the Standard/High/Extra High quality tiers).

import PackageDescription

let package = Package(
    name: "Ora",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .executable(name: "ora", targets: ["Ora"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift", from: "0.0.9"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        // HF hub downloader — DePasqualeOrg/swift-hf-api. We vendor the ~50-line
        // Downloader adapter in MLXAdapters.swift because the upstream -mlx adapter
        // pins mlx-swift-lm to a conflicting SHA.
        .package(url: "https://github.com/DePasqualeOrg/swift-hf-api", branch: "main"),
        // Tokenizer — HuggingFace's swift-transformers (already transitively pulled
        // by speech-swift; we declare it directly to access the `Tokenizers` product).
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
    ],
    targets: [
        .executableTarget(
            name: "Ora",
            dependencies: [
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HFAPI", package: "swift-hf-api"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
