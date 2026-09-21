// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ThisJellyFix",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "ThisJellyFixFeature", targets: ["ThisJellyFixFeature"]),
        .library(name: "ThisJellyFixPlayback", targets: ["ThisJellyFixPlayback"])
    ],
    targets: [
        .target(name: "ThisJellyFixCore"),
        .target(name: "ThisJellyFixNetworking", dependencies: ["ThisJellyFixCore"]),
        .target(
            name: "ThisJellyFixFeature",
            dependencies: ["ThisJellyFixCore", "ThisJellyFixNetworking"]
        ),
        .target(name: "ThisJellyFixPlayback", dependencies: ["ThisJellyFixCore"]),
        .testTarget(name: "ThisJellyFixCoreTests", dependencies: ["ThisJellyFixCore"]),
        .testTarget(
            name: "ThisJellyFixNetworkingTests",
            dependencies: ["ThisJellyFixNetworking"]
        )
    ]
)
