// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Onyx",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "Onyx", targets: ["Onyx"]),
    ],
    targets: [
        .executableTarget(
            name: "Onyx",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "OnyxTests",
            dependencies: ["Onyx"]
        ),
    ]
)
