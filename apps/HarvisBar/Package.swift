// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HarvisBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "HarvisBar", targets: ["HarvisBar"]),
        .executable(
            name: "HarvisPerAppProxyExtension",
            targets: ["HarvisPerAppProxyExtension"]
        ),
        .library(name: "HarvisProxyCore", targets: ["HarvisProxyCore"]),
        .library(name: "HarvisVersionCore", targets: ["HarvisVersionCore"])
    ],
    targets: [
        .target(
            name: "HarvisVersionCore",
            path: "Sources/HarvisVersionCore"
        ),
        .target(
            name: "HarvisProxyCore",
            path: "Sources/HarvisProxyCore"
        ),
        .executableTarget(
            name: "HarvisPerAppProxyExtension",
            dependencies: ["HarvisProxyCore"],
            path: "SystemExtensions/HarvisPerAppProxyExtension",
            exclude: [
                "Info.plist",
                "HarvisPerAppProxyExtension.entitlements"
            ]
        ),
        .executableTarget(
            name: "HarvisBar",
            dependencies: ["HarvisProxyCore", "HarvisVersionCore"],
            path: "Sources/HarvisBar"
        ),
        .testTarget(
            name: "HarvisProxyCoreTests",
            dependencies: ["HarvisProxyCore"],
            path: "Tests/HarvisProxyCoreTests"
        ),
        .testTarget(
            name: "HarvisBarTests",
            dependencies: ["HarvisBar", "HarvisVersionCore"],
            path: "Tests/HarvisBarTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
