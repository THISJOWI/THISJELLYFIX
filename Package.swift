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
    dependencies: [
        .package(url: "https://github.com/virtualox/vlckit-spm.git", from: "4.0.0-alpha.21")
    ],
    targets: [
        .target(name: "ThisJellyFixCore"),
        .target(name: "ThisJellyFixNetworking", dependencies: ["ThisJellyFixCore"]),
        .target(
            name: "ThisJellyFixFeature",
            dependencies: ["ThisJellyFixCore", "ThisJellyFixNetworking", "ThisJellyFixPlayback"]
        ),
        .target(name: "ThisJellyFixPlayback", dependencies: ["ThisJellyFixCore", .product(name: "VLCKitSPM", package: "vlckit-spm")]),
        .testTarget(name: "ThisJellyFixCoreTests", dependencies: ["ThisJellyFixCore"]),
        .testTarget(
            name: "ThisJellyFixNetworkingTests",
            dependencies: ["ThisJellyFixNetworking"]
        )
    ]
)
