// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MantisNative",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MantisNative", targets: ["Mantis"]), .library(name: "MantisCore", targets: ["MantisCore"])],
    targets: [
        .target(name: "MantisCore"),
        .executableTarget(name: "Mantis", dependencies: ["MantisCore"]),
        .testTarget(name: "MantisCoreTests", dependencies: ["MantisCore", "Mantis"])
    ]
)
