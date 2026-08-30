import Foundation

/// 壳的磁盘位置。M1 起壳不再管理 dsh 安装，这里只剩自己的日志与
/// dsh 写来的 endpoint 发现文件。
enum ClamPaths {
    /// ~/Library/Application Support/io.wenbo.surfclam/
    /// Debug 与 Release 共用同一目录：endpoint 发现文件由 dsh 写，
    /// 两个构建都要读到同一份（bundle id 不同但落点必须一致）。
    static let appSupport: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("io.wenbo.surfclam", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let logsDir: URL = {
        let dir = appSupport.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 这份产物属于哪一套代码（多 worktree 时的实例标签）。
    ///
    /// Debug 产物落在 `<worktree>/clam-app/host/build/Build/Products/Debug/`，
    /// 路径里 `clam-app` 前面那一段就是 worktree 目录名。装到 `/Applications`
    /// 的 Release 全机只有一份，返回 nil（不加后缀）。
    ///
    /// 跟着**产物**分片而不是跟着连上的 dsh：壳可以断连重连到别的 dsh，
    /// 但它跑的始终是同一份代码，编译错误与插件世代都归这份代码。
    static let instanceTag: String? = {
        guard let i = clamAppIndex, i > 0 else { return nil }
        return Bundle.main.bundleURL.pathComponents[i - 1]
    }()

    /// 本产物是从哪个 `clam-app/host` 构建出来的（绝对路径，Release 安装包为 nil）。
    ///
    /// clam-app 插件把同一个路径写进 endpoint 发现文件，壳凭它认出
    /// "哪一份是我这一套"——见 `ClamEndpoint.isOwn`。
    ///
    /// **对装到 `/Applications` 的 Release 产物恒为 nil**（路径里没有 `clam-app`
    /// 那一段），那种场合由发现文件里的 `appPath` 字段兜底。
    static let ownHostDir: String? = {
        let parts = Bundle.main.bundleURL.pathComponents
        guard let i = clamAppIndex, i + 1 < parts.count, parts[i + 1] == "host" else { return nil }
        return NSString.path(withComponents: Array(parts[0...(i + 1)]))
    }()

    /// bundle 路径里 `clam-app` 那一段的下标。开发期产物固定落在
    /// `<worktree>/clam-app/host/build/Build/Products/<配置>/`；装到
    /// `/Applications` 的 Release 里没有这一段。
    private static let clamAppIndex: Int? = {
        Bundle.main.bundleURL.pathComponents.lastIndex(of: "clam-app")
    }()

    /// 壳自己的日志（dsh 的输出归它自己的终端）。
    ///
    /// **一个实例一份**（`surfclam.<worktree>.log`）：多 worktree 并存时，两个
    /// App 实例的 bundle id 相同、日志目录也相同，共用一个文件就会把邻居的
    /// 插件编译错误混进来——而那种错误看上去和自己的一模一样，误诊代价很高。
    static let logURL: URL = {
        let name = instanceTag.map { "surfclam.\($0).log" } ?? "surfclam.log"
        return logsDir.appendingPathComponent(name)
    }()

    /// clam-app 插件在 dsh 启动时写、退出时删；壳三级定位的第二级。
    ///
    /// **一个 profile 一份**（`endpoints/<profile>.json`）。一台机器上可以同时
    /// 跑好几个 dsh——每个 git worktree 一套插件、一个 profile、一个 App 实例；
    /// 共用一份文件的话后启动的会把先启动的抹掉。壳这边因此是"扫目录取候选"，
    /// 而不是"读一个文件"（见 `EndpointLocator.discoveredEndpoints`）。
    static let endpointsDir = appSupport.appendingPathComponent("endpoints", isDirectory: true)
}
