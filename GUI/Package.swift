// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MantisNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MantisNative", targets: ["Mantis"]),
        .executable(name: "MantisUpdater", targets: ["MantisUpdater"]),
        .library(name: "MantisCore", targets: ["MantisCore"])
    ],
    targets: [
        .target(name: "MantisCore"),
        .executableTarget(name: "Mantis", dependencies: ["MantisCore"]),
        .executableTarget(name: "MantisUpdater", dependencies: ["MantisCore"]),
        .testTarget(name: "MantisCoreTests", dependencies: ["MantisCore", "Mantis"])
    ]
)
