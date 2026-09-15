// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sukiru",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SukiruCore", targets: ["SukiruCore"]),
        .executable(name: "sukiru-cli", targets: ["sukiru-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.4.0")
    ],
    targets: [
        .target(
            name: "SukiruCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
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
