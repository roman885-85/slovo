// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Slovo",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "SlovoCore"),
        .executableTarget(name: "Slovo", dependencies: ["SlovoCore"]),
        .executableTarget(name: "slovo-scan", dependencies: ["SlovoCore"]),
        .testTarget(name: "SlovoCoreTests", dependencies: ["SlovoCore"], path: "Tests/SlovoCoreTests"),
    ]
)
