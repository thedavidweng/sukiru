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
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0")
    ],
    targets: [
        .target(
            name: "SukiruCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .executableTarget(
            name: "sukiru-cli",
            dependencies: [
                "SukiruCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "SukiruCoreTests",
            dependencies: ["SukiruCore"]
        ),
    ]
)
