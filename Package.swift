// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LilMac",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LilMac", targets: ["LilMac"]),
        .library(name: "LilMacRuntime", targets: ["LilMacRuntime"]),
        .library(name: "LilMacMCP", targets: ["LilMacMCP"]),
        .library(name: "LilMacTools", targets: ["LilMacTools"]),
        .executable(name: "lilmac-eval", targets: ["lilmac-eval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
    ],
    targets: [
        .target(name: "LilMac"),
        .target(name: "LilMacRuntime", dependencies: ["LilMac"]),
        .target(name: "LilMacTools", dependencies: ["LilMac"]),
        .target(name: "LilMacMCP", dependencies: [
            "LilMac",
            .product(name: "MCP", package: "swift-sdk"),
        ]),
        .executableTarget(name: "lilmac-eval", dependencies: ["LilMac", "LilMacTools"]),
        .testTarget(name: "LilMacTests", dependencies: ["LilMac"]),
        .testTarget(name: "LilMacRuntimeTests", dependencies: ["LilMacRuntime", "LilMac"]),
        .testTarget(name: "LilMacMCPTests", dependencies: ["LilMacMCP"]),
        .testTarget(name: "LilMacToolsTests", dependencies: ["LilMacTools"]),
    ],
    swiftLanguageModes: [.v6]
)
