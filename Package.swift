// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Awake", targets: ["Awake"]),
        .executable(name: "awakectl", targets: ["awakectl"]),
        .library(name: "AwakeCore", targets: ["AwakeCore"])
    ],
    targets: [
        .target(
            name: "AwakeCore"
        ),
        .executableTarget(
            name: "Awake",
            dependencies: ["AwakeCore"],
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "awakectl",
            dependencies: ["AwakeCore"]
        ),
        .testTarget(
            name: "AwakeTests",
            dependencies: ["AwakeCore"]
        )
    ]
)
