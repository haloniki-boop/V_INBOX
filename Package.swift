// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GitOperation",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GitCore", targets: ["GitCore"]),
        .executable(name: "GitCoreSelfTest", targets: ["GitCoreSelfTest"]),
        .executable(name: "GitCoreIntegrationTest", targets: ["GitCoreIntegrationTest"])
    ],
    targets: [
        .target(name: "GitCore"),
        .executableTarget(
            name: "GitCoreSelfTest",
            dependencies: ["GitCore"],
            path: "Tests/GitCoreSelfTests"
        ),
        .executableTarget(
            name: "GitCoreIntegrationTest",
            dependencies: ["GitCore"],
            path: "Tests/GitCoreIntegrationTests"
        )
    ]
)
