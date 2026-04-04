// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "flutter_mesh_network",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "flutter-mesh-network", targets: ["flutter_mesh_network"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "flutter_mesh_network",
            dependencies: [],
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
