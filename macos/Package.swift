// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SaysoNotch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SaysoCore", targets: ["SaysoCore"]),
        .library(name: "SaysoGalleryUI", targets: ["SaysoGalleryUI"]),
        .executable(name: "SaysoGallery", targets: ["SaysoGallery"]),
        .executable(name: "SaysoNotch", targets: ["SaysoNotch"]),
        .executable(name: "sayso", targets: ["SaysoCLI"]),
        .executable(name: "sayso-mcp", targets: ["SaysoMCP"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/crmitchelmore/justspeaktoit.git",
            revision: "bd06625ff62e0f9b3ae9743312723420adc966bc"
        ),
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
        .package(
            url: "https://github.com/k2-fsa/sherpa-onnx.git",
            exact: "1.13.8"
        ),
    ],
    targets: [
        .target(
            name: "SaysoCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
                .product(name: "SpeakCore", package: "justspeaktoit"),
                .product(name: "SpeakHotKeys", package: "justspeaktoit"),
            ]
        ),
        .target(
            name: "SpeakUpstreamBridge",
            dependencies: [
                .product(name: "SpeakCore", package: "justspeaktoit"),
                .product(name: "SpeakAutomationKit", package: "justspeaktoit"),
                .product(name: "SpeakHotKeys", package: "justspeaktoit"),
            ]
        ),
        .executableTarget(
            name: "SaysoNotch",
            dependencies: ["SaysoCore", "SpeakUpstreamBridge"]
        ),
        .executableTarget(
            name: "SaysoCLI",
            dependencies: ["SaysoCore", "SpeakUpstreamBridge"],
            path: "Sources/speak"
        ),
        .executableTarget(name: "SaysoMCP", dependencies: ["SaysoCore", "SpeakUpstreamBridge"], path: "Sources/sayso-mcp"),
        .target(name: "SaysoGalleryUI", dependencies: ["SaysoCore"]),
        .executableTarget(name: "SaysoGallery", dependencies: ["SaysoCore", "SaysoGalleryUI"]),
        .testTarget(name: "SaysoNotchTests", dependencies: ["SaysoNotch", "SaysoCore"]),
        .testTarget(name: "SaysoGalleryUITests", dependencies: ["SaysoCore", "SaysoGalleryUI"]),
        .testTarget(name: "SaysoCoreTests", dependencies: ["SaysoCore", .product(name: "SpeakHotKeys", package: "justspeaktoit")]),
    ]
)
