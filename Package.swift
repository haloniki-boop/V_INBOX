// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GitOperation",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GitCore", targets: ["GitCore"]),
        .executable(name: "GitCoreSelfTest", targets: ["GitCoreSelfTest"])
    ],
    targets: [
        .target(name: "GitCore"),
        .executableTarget(
            name: "GitCoreSelfTest",
            dependencies: ["GitCore"],
            path: "Tests/GitCoreSelfTests"
        )
    ]
)
