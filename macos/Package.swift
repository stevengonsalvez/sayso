// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SaysoNotch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SaysoCore", targets: ["SaysoCore"]),
        .executable(name: "SaysoNotch", targets: ["SaysoNotch"]),
        .executable(name: "sayso", targets: ["SaysoCLI"]),
        .executable(name: "sayso-mcp", targets: ["SaysoMCP"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/crmitchelmore/justspeaktoit.git",
            revision: "0f0e92028a249e17b58349da3ee8033c73ffd219"
        ),
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
    ],
    targets: [
        .target(
            name: "SaysoCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
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
        .testTarget(name: "SaysoCoreTests", dependencies: ["SaysoCore"]),
    ]
)
