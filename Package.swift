// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Signet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Signet", targets: ["Signet"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Signet",
            dependencies: [],
            path: "Sources/Signet",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "SignetTests",
            dependencies: ["Signet"],
            path: "Tests/SignetTests"
        )
    ]
)
