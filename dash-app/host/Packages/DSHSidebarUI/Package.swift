// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DSHSidebarUI",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "DSHSidebarUI", targets: ["DSHSidebarUI"]),
    ],
    dependencies: [
        // 平台无关的协议客户端与镜像模型（本地包）。
        .package(path: "../DSHKit"),
    ],
    targets: [
        .target(name: "DSHSidebarUI", dependencies: ["DSHKit"]),
    ]
)
