// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mac-compute-swift",
    platforms: [
        // Vision's text and multimodal path plus the Foundation Models
        // framework start at macOS 26; the narrative pass needs 27.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "ml-mcp", targets: ["MLMCP"]),
        .executable(name: "media-mcp", targets: ["MediaMCP"]),
        .executable(name: "video-mcp", targets: ["VideoMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "MLMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .executableTarget(
            name: "MediaMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .executableTarget(
            name: "VideoMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "MLMCPTests",
            dependencies: ["MLMCP"]
        ),
    ]
)
