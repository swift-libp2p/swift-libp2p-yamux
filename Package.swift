// swift-tools-version: 5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-libp2p-yamux",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "LibP2PYAMUX",
            targets: ["LibP2PYAMUX"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.

        // LibP2P Core Modules
        .package(url: "https://github.com/swift-libp2p/swift-libp2p.git", .upToNextMinor(from: "0.2.0")),

        // NIO Test Utils
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.0.0")),

    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "LibP2PYAMUX",
            dependencies: [
                .product(name: "LibP2P", package: "swift-libp2p")
            ]
        ),
        .testTarget(
            name: "LibP2PYAMUXTests",
            dependencies: [
                "LibP2PYAMUX",
                .product(name: "NIOTestUtils", package: "swift-nio"),
            ]
        ),
    ]
)
