// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DSHKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "DSHKit", targets: ["DSHKit"]),
        .executable(name: "dshkit-cli", targets: ["dshkit-cli"])
    ],
    targets: [
        .target(name: "DSHKit"),
        .executableTarget(name: "dshkit-cli", dependencies: ["DSHKit"]),
        .testTarget(name: "DSHKitTests", dependencies: ["DSHKit"])
    ]
)
