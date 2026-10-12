// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Oculuxus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Oculuxus", targets: ["Oculuxus"]),
    ],
    targets: [
        .executableTarget(
            name: "Oculuxus",
            path: "Sources/Oculuxus"
        ),
        .testTarget(
            name: "OculuxusTests",
            dependencies: ["Oculuxus"],
            path: "Tests/OculuxusTests"
        ),
    ]
)
