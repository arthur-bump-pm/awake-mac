// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Outpost",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Outpost", targets: ["Outpost"]),
        .executable(name: "outpostctl", targets: ["outpostctl"]),
        .library(name: "OutpostCore", targets: ["OutpostCore"])
    ],
    targets: [
        .target(
            name: "OutpostCore"
        ),
        .executableTarget(
            name: "Outpost",
            dependencies: ["OutpostCore"],
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "outpostctl",
            dependencies: ["OutpostCore"]
        ),
        .testTarget(
            name: "OutpostTests",
            dependencies: ["OutpostCore"]
        )
    ]
)
