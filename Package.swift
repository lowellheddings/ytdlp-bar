// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "YTDLPBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YTDLPBar", targets: ["YTDLPBar"])
    ],
    targets: [
        .target(name: "YTDLPBarCore"),
        .executableTarget(
            name: "YTDLPBar",
            dependencies: ["YTDLPBarCore"]
        ),
        .testTarget(
            name: "YTDLPBarTests",
            dependencies: ["YTDLPBarCore"]
        ),
    ]
)
