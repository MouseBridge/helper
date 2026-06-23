// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MouseBridgeHelper",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "mousebridge-helper", targets: ["MouseBridgeHelper"]),
    ],
    targets: [
        .executableTarget(
            name: "MouseBridgeHelper",
            path: "Sources"
        ),
    ]
)
