// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FoundationModelEval",
    platforms: [
        .macOS("26")
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMajor(from: "0.1.21")),
    ],
    targets: [
        .executableTarget(
            name: "FoundationModelEval",
            dependencies: [.product(name: "Transformers", package: "swift-transformers")]
        ),
    ]
)
