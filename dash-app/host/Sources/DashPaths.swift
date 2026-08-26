import Foundation

/// 壳的磁盘位置。M1 起壳不再管理 dsh 安装，这里只剩自己的日志与
/// dsh 写来的 endpoint 发现文件。
enum DashPaths {
    /// ~/Library/Application Support/io.wenbo.dash/
    /// Debug 与 Release 共用同一目录：endpoint 发现文件由 dsh 写，
    /// 两个构建都要读到同一份（bundle id 不同但落点必须一致）。
    static let appSupport: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("io.wenbo.dash", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let logsDir: URL = {
        let dir = appSupport.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 壳自己的日志（dsh 的输出归它自己的终端）。
    static let logURL = logsDir.appendingPathComponent("dash.log")

    /// dash-app 插件在 dsh 启动时写、退出时删；壳三级定位的第二级。
    ///
    /// **一个 profile 一份**（`endpoints/<profile>.json`）。一台机器上可以同时
    /// 跑好几个 dsh——每个 git worktree 一套插件、一个 profile、一个 App 实例；
    /// 共用一份文件的话后启动的会把先启动的抹掉。壳这边因此是"扫目录取候选"，
    /// 而不是"读一个文件"（见 `EndpointLocator.discoveredEndpoints`）。
    static let endpointsDir = appSupport.appendingPathComponent("endpoints", isDirectory: true)
}
