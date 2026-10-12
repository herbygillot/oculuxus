// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Oculuxus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Oculuxus", targets: ["Oculuxus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: [
        .executableTarget(
            name: "Oculuxus",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/Oculuxus",
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "OculuxusTests",
            dependencies: ["Oculuxus"],
            path: "Tests/OculuxusTests"
        ),
    ]
)
