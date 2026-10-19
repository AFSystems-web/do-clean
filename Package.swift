// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DoClean",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DoCleanApp", targets: ["DoClean"]),
        .executable(name: "doclean", targets: ["doclean-cli"]),
    ],
    targets: [
        .target(
            name: "DoCleanCore",
            resources: [.copy("Rules")]
        ),
        .target(
            name: "DoCleanUI",
            dependencies: ["DoCleanCore"]
        ),
        .executableTarget(
            name: "DoClean",
            dependencies: ["DoCleanCore", "DoCleanUI"]
        ),
        .executableTarget(
            name: "doclean-cli",
            dependencies: ["DoCleanCore"]
        ),
        .testTarget(name: "DoCleanCoreTests", dependencies: ["DoCleanCore"]),
        .testTarget(name: "DoCleanUITests", dependencies: ["DoCleanUI"]),
    ]
)
