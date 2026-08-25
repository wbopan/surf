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
    // DSHKit 依赖已移除：源码层面从未使用（M2 实测确认），
    // 且 DSHKit 现在是随 bundle 分发的共享 dylib，不能再被静态链一份进来。
    targets: [
        .target(name: "DSHSidebarUI"),
    ]
)
