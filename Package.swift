// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sukiru",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SukiruCore", targets: ["SukiruCore"]),
        .executable(name: "sukiru", targets: ["sukiru-cli"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "SukiruCore",
            dependencies: []
        ),
        .executableTarget(
            name: "sukiru-cli",
            dependencies: ["SukiruCore"]
        ),
        .testTarget(
            name: "SukiruCoreTests",
            dependencies: ["SukiruCore"]
        ),
    ]
)
