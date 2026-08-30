import Foundation

/// **profile 自举**：让"双击 `/Applications/Surfclam.app`"这一下就足以跑起一整套
/// surfclam，用户机器上不需要仓库、不需要 pnpm、不需要知道 profile 是什么。
/// 权威计划 `docs/distribution-plan.md` §2.2 / §3.5 / §7.1。
///
/// 做四件事，全部**增量确保**，不是覆盖重写：
///
/// 1. **profile 目录在不在**——不在就按 dsh 自己的 `initProfile` 模板建
///    （`dsh-app-boot/lib/index.js:353-369`：`package.json` / `cordis.patch.yml` /
///    `pnpm-workspace.yaml` 三样，**没有 `cordis.yml`**——那份 dsh 每次启动都
///    无条件重写，我们写了也是白写）。
/// 2. **镜像**：`Contents/Resources/ClamNode/` → `<profile>/.surfclam/`。
///    判据是 `.stamp`（`{appVersion, appPath, sourceHash}`）；对得上就一个字节
///    都不动。**不能用 mtime 当判据**——`ditto` 连同源目录的 mtime 一起拷，
///    而 bundle 里那个目录的 mtime 停在它第一次被创建的那一刻（CLAUDE.md 的
///    图标缓存那条坑同源）。
/// 3. **`package.json`**：给每个镜像里的包补一行 `link:./.surfclam/<pkg>`，
///    并把 `dsh.profile.bundles` 补齐成那三行。
/// 4. **符号链接**：`<profile>/node_modules/@wenbo/<pkg>` → `../../.surfclam/<pkg>`。
///
/// **不调 pnpm**（计划 §7.2，已实测定案）：pnpm 对 `link:` 依赖不写 lockfile
/// 条目，所以之后用户跑 `dsh plugin add` / `pnpm install` / 甚至
/// `--frozen-lockfile`，我们手建的链接都原样保留。这顺带消掉了"GUI App 的
/// PATH 里找不到 pnpm"这一整类问题。**但第 3 步不能省**：pnpm 会 prune 掉
/// `package.json` 里没有的 `node_modules` 条目，写了它，用户误跑 pnpm 时才是
/// **重建**同样的布局而不是删掉我们的链接。
///
/// ## 三条纪律（计划 §3.5，用户往这个 profile 里加的东西必须活下来）
///
/// 1. **只读-改-写我们那几个 key 和 `bundles` 那三行**，绝不整体重写
///    `package.json`——用户 `dsh plugin add` 的依赖跟我们那几行躺在同一个
///    `dependencies` 对象里。**保序、保缩进**：所以这里自带一个保序的 JSON
///    编解码（`OrderedJSON`），而不是 `JSONSerialization`（它的字典无序）。
/// 2. **绝不碰 `<profile>/cordis.patch.yml`**——那是 dsh 给用户的 patch 层，
///    叠在我们的编排表之上，用户可以用它 disable 我们任何一个插件。
///    只有"profile 整个不存在"时才按 dsh 的模板建一份空的。
/// 3. **对不上就 fails loud，不要"修复"回默认。**
///
/// ## 只在 Release 壳跑
///
/// 判据**不是** `#if DEBUG`（这个工程两边都不成立，见 CLAUDE.md），而是
/// `BackendManager` 本来就在区分的"我 spawn 什么"：Dev 壳跑本 worktree 的
/// `./dev`，那个 profile 由 `./dev` 自己备（link 仓库源码），**自举那段代码
/// 路径压根不该走到**。两种形态的 profile 名也不同（`surfclam` vs
/// `surfclam-dev`，计划 §3.6），所以它们不再互相覆盖。
enum ProfileBootstrap {

    /// 自举失败。**一律 fails loud**：`BackendManager` 把它翻成
    /// `.unavailable(.bootstrapFailed)` 摆到连接页上，而不是静默降级。
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 安装形态专属的 profile 名（计划 §3.6）。开发形态一律带后缀。
    static let profileName = "surfclam"

    /// 镜像在 profile 里的位置。点号开头有两个好处：`pnpm-workspace.yaml` 的
    /// `packages: [.]` 不会把它当成 workspace 成员（实测），Finder 里也不碍眼。
    static let mirrorDirName = ".surfclam"

    /// 一次自举的结果（写进日志与诊断面板，界面上不出现）。
    struct Outcome {
        let profileDir: URL
        /// 镜像里的包（包名）。
        let packages: [String]
        let profileCreated: Bool
        let mirrorRefreshed: Bool
        let manifestChanged: Bool
        let linksChanged: Int

        var summary: String {
            "profile \(profileDir.path)：\(packages.count) 个包"
                + (profileCreated ? "，新建 profile" : "")
                + (mirrorRefreshed ? "，镜像已刷新" : "，镜像未变动")
                + (manifestChanged ? "，package.json 已更新" : "")
                + (linksChanged > 0 ? "，\(linksChanged) 条链接已修" : "")
        }
    }

    // MARK: - 载荷

    /// bundle 里那份 node 半边（`Contents/Resources/ClamNode/`，由
    /// `scripts/pack-payload.sh` 打进来）。**不在 = 这个壳不带载荷**，
    /// 自举无事可做（开发形态、或 M1 之前的旧产物）。
    static var payloadRoot: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent("ClamNode", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return dir
    }

    /// 打包时写下的清单（`Contents/Resources/ClamPayload.json`）。它里面那个
    /// `hash` 就是载荷的内容 hash——**直接用它当 `.stamp` 的 `sourceHash`**，
    /// 免得每次启动重新遍历几百 KB 去算一遍同一个数。
    private static func payloadManifest() -> (hash: String, version: String)? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("ClamPayload.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hash = obj["hash"] as? String else { return nil }
        return (hash, (obj["version"] as? String) ?? "?")
    }

    // MARK: - 入口

    /// 跑一次自举。**幂等**：什么都没变时不写任何一个字节。
    ///
    /// - Parameters:
    ///   - profile: profile 名，缺省 `surfclam`。
    ///   - home: dsh 的 home（`$DSH_HOME`，缺省 `~/.dsh`）。
    /// - Returns: 载荷不在场时返回 nil（不是错误——那就是"这个壳不带载荷"）。
    /// - Throws: `Failure`，任何一条纪律被触碰、或磁盘操作失败。
    @discardableResult
    static func run(profile: String = profileName, home: URL? = nil) throws -> Outcome? {
        guard let payload = payloadRoot else {
            log("bundle 里没有 ClamNode 载荷，跳过自举（这个壳不带 node 半边）")
            return nil
        }
        let dshHome = home ?? resolveDshHome()
        let dir = dshHome.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)

        let packages = try readPayloadPackages(payload)
        let created = try ensureProfileSkeleton(dir)
        // 迁移检查先于任何写盘（计划 §7.1）：旧的开发形态残留必须**报出去**，
        // 不能被我们悄悄改写成镜像——那等于把开发者的仓库从运行链上摘掉。
        try assertNoForeignLinks(dir: dir, packages: packages, profile: profile)
        let refreshed = try syncMirror(payload: payload, into: dir)
        let manifestChanged = try updateManifest(dir: dir, packages: packages, profile: profile)
        let links = try updateLinks(dir: dir, packages: packages)

        let outcome = Outcome(profileDir: dir, packages: packages.map(\.name),
                              profileCreated: created, mirrorRefreshed: refreshed,
                              manifestChanged: manifestChanged, linksChanged: links)
        log("自举完成：\(outcome.summary)")
        return outcome
    }

    // MARK: - dsh home

    /// `$DSH_HOME`，缺省 `~/.dsh`（与 `@deepseek-ai/dsh-home-paths` 的
    /// `resolveDshHome` 同一套优先级：空串/纯空白当未设）。
    ///
    /// **必须经 login shell 问一遍**：GUI App 继承的环境里没有用户的
    /// `.zprofile`，而我们 spawn 的那个 dsh 走的正是 `zsh -lc`——两边算出不同的
    /// home 就会自举到一个没人读的目录去，而且完全不报错。
    /// （`zsh -lc` 读 `.zshenv`/`.zprofile`/`.zlogin`，**不读 `.zshrc`**。）
    static func resolveDshHome() -> URL {
        let fromLoginShell = loginShellValue("DSH_HOME")
        let raw = [ProcessInfo.processInfo.environment["DSH_HOME"], fromLoginShell]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh", isDirectory: true)
        }
        if path == "~" { path = NSHomeDirectory() }
        else if path.hasPrefix("~/") { path = NSHomeDirectory() + String(path.dropFirst(1)) }
        return URL(fileURLWithPath: (path as NSString).standardizingPath)
    }

    private static func loginShellValue(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "printf %s \"${\(name)}\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 载荷清单

    /// 镜像里的一个包。`dir` 是目录名（= 仓库里的目录名，clam-* 之间的相对
    /// import 全靠它），`name` 是 `package.json` 里的包名。
    struct Package {
        let dir: String
        let name: String
        /// 声明了 `dsh.bundle` 的那个 = 伞包，profile 的 `bundles` 里认的就是它。
        let isBundle: Bool
    }

    private static func readPayloadPackages(_ payload: URL) throws -> [Package] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: payload.path))?.sorted() ?? []
        var out: [Package] = []
        for entry in entries where !entry.hasPrefix(".") {
            let manifest = payload.appendingPathComponent(entry).appendingPathComponent("package.json")
            guard let data = try? Data(contentsOf: manifest),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["name"] as? String else { continue }
            let bundle = (obj["dsh"] as? [String: Any])?["bundle"] != nil
            out.append(Package(dir: entry, name: name, isBundle: bundle))
        }
        guard !out.isEmpty else {
            throw Failure(message: "bundle 里的 ClamNode 载荷是空的：\(payload.path)")
        }
        guard out.contains(where: \.isBundle) else {
            throw Failure(message: "ClamNode 载荷里没有任何包声明 dsh.bundle（伞包缺失），"
                          + "profile 的 bundles 无从写起：\(payload.path)")
        }
        return out
    }

    // MARK: - ① profile 骨架

    /// 照 dsh 的 `initProfile` 建，**已存在的文件一个都不碰**（它自己也是这个语义）。
    /// - Returns: 这次是不是新建的。
    private static func ensureProfileSkeleton(_ dir: URL) throws -> Bool {
        let fm = FileManager.default
        let manifest = dir.appendingPathComponent("package.json")
        let existed = fm.fileExists(atPath: manifest.path)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if !existed {
            // 与 dsh 的模板逐字一致：`JSON.stringify(manifest, undefined, 2) + "\n"`，
            // 只有 `dsh-base` 一层（`PROFILE_TEMPLATES` 里没有我们这个名字，
            // web 那一层要自己补——`updateManifest` 干这件事）。
            let seed = OrderedJSON.object([
                ("name", .string("dsh-profile-\(dir.lastPathComponent)")),
                ("private", .bool(true)),
                ("dependencies", .object([])),
                ("dsh", .object([
                    ("profile", .object([
                        ("bundles", .array([.string("@deepseek-ai/dsh-base")])),
                    ])),
                ])),
            ])
            try write(seed.serialized(indent: "  ") + "\n", to: manifest)
        }
        // **用户的 patch 层**：只有整个不存在时才建一份空的，之后一个字都不碰。
        let patch = dir.appendingPathComponent("cordis.patch.yml")
        if !fm.fileExists(atPath: patch.path) {
            try write("""
            # Your patch layer for this dsh profile, applied after every bundle layer:
            # a top-level YAML array of loader patch entries (id-targeted config
            # overrides, disables, and insert lists; `!!js` expressions allowed).
            []

            """, to: patch)
        }
        let workspace = dir.appendingPathComponent("pnpm-workspace.yaml")
        if !fm.fileExists(atPath: workspace.path) {
            try write("""
            packages:
              - .

            nodeLinker: hoisted
            autoInstallPeers: false

            """, to: workspace)
        }
        // **绝不写 `cordis.yml`**：dsh 每次启动都无条件重写它
        // （`profile-boot-*.js` 的 `prepareProfile`），我们写的当场作废。
        return !existed
    }

    // MARK: - ② 迁移检查（计划 §7.1）

    /// 我们那几行的 link 目标指到 `.surfclam/` 以外去了 = 这个 profile 是别的
    /// 形态留下的（典型：改名之前主 worktree 的 `./dev` 就装在 `surfclam` 上）。
    /// **停下来报出去，不覆盖**——覆盖等于把开发者的仓库从运行链上摘掉，
    /// 症状是"我明明在改代码，怎么一点反应都没有"。
    private static func assertNoForeignLinks(dir: URL, packages: [Package], profile: String) throws {
        let manifestURL = dir.appendingPathComponent("package.json")
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8),
              let doc = try? OrderedJSON.parse(text),
              case .object(let root) = doc,
              let deps = root.first(where: { $0.key == "dependencies" })?.value,
              case .object(let entries) = deps else { return }

        let known = Set(packages.map(\.name))
        for (key, value) in entries where known.contains(key) {
            guard case .string(let spec) = value else {
                throw migration(profile: profile, package: key, spec: "(不是字符串)")
            }
            guard isMirrorLink(spec) else {
                throw migration(profile: profile, package: key, spec: spec)
            }
        }
    }

    private static func isMirrorLink(_ spec: String) -> Bool {
        spec.hasPrefix("link:./\(mirrorDirName)/") || spec.hasPrefix("link:\(mirrorDirName)/")
    }

    private static func migration(profile: String, package: String, spec: String) -> Failure {
        Failure(message: """
        profile \(profile) 是旧的开发形态残留：\(package) 指向 \(spec)，\
        不是 App 自举的镜像（link:./\(mirrorDirName)/…）。自举没有改动它。
        删掉它（rm -rf ~/.dsh/profiles/\(profile)）后重开 App，或者跑一次 ./dev 迁移到 surfclam-dev。
        """)
    }

    // MARK: - ③ 镜像

    private struct Stamp: Codable, Equatable {
        var appVersion: String
        var appPath: String
        var sourceHash: String
    }

    private static func currentStamp(payload: URL) throws -> Stamp {
        let manifest = payloadManifest()
        let hash = try manifest?.hash ?? contentHash(of: payload)
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return Stamp(appVersion: "\(short ?? manifest?.version ?? "?") (\(build ?? "?"))",
                     appPath: Bundle.main.bundlePath,
                     sourceHash: hash)
    }

    /// 载荷没有 `ClamPayload.json` 时的兜底：自己遍历一遍算内容 hash。
    /// **只哈希内容与相对路径，不碰 mtime**——`ditto` 会把源目录的 mtime 一起
    /// 拷过来，拿它当判据必然踩坑。
    private static func contentHash(of root: URL) throws -> String {
        let fm = FileManager.default
        var files: [String] = []
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw Failure(message: "读不了载荷目录：\(root.path)")
        }
        for case let url as URL in walker {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            files.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        var hasher = SHA256Hasher()
        for rel in files.sorted() {
            hasher.update(rel)
            hasher.update((try? Data(contentsOf: root.appendingPathComponent(rel))) ?? Data())
        }
        return hasher.finalizeHex()
    }

    /// - Returns: 这次有没有真的重拷。
    private static func syncMirror(payload: URL, into dir: URL) throws -> Bool {
        let fm = FileManager.default
        let mirror = dir.appendingPathComponent(mirrorDirName, isDirectory: true)
        let stampURL = mirror.appendingPathComponent(".stamp")
        let want = try currentStamp(payload: payload)

        if let data = try? Data(contentsOf: stampURL),
           let have = try? JSONDecoder().decode(Stamp.self, from: data),
           have == want,
           fm.fileExists(atPath: mirror.path) {
            return false
        }

        // 整体换而不是就地合并：上一版打进去、这一版不再在册的包必须消失，
        // 否则镜像里会留一份没人加载的陈尸（`pack-payload.mjs` 同款理由）。
        let incoming = dir.appendingPathComponent("\(mirrorDirName).incoming", isDirectory: true)
        let retiring = dir.appendingPathComponent("\(mirrorDirName).old", isDirectory: true)
        try? fm.removeItem(at: incoming)
        try? fm.removeItem(at: retiring)
        try ditto(payload, incoming)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (try encoder.encode(want)).write(to: incoming.appendingPathComponent(".stamp"))

        if fm.fileExists(atPath: mirror.path) {
            try fm.moveItem(at: mirror, to: retiring)
        }
        do {
            try fm.moveItem(at: incoming, to: mirror)
        } catch {
            // 换不上就把旧的放回去——半个镜像比旧镜像糟得多。
            if fm.fileExists(atPath: retiring.path) { try? fm.moveItem(at: retiring, to: mirror) }
            throw Failure(message: "镜像换代失败：\(error.localizedDescription)")
        }
        try? fm.removeItem(at: retiring)
        log("镜像已刷新 → \(mirror.path)（\(want.appVersion)，\(want.sourceHash.prefix(12))）")
        return true
    }

    /// `ditto` 而不是 `FileManager.copyItem`：它是这个仓库两条安装路径一直用的
    /// 那一个（metadata 与符号链接语义都对），行为上少一份意外。
    private static func ditto(_ from: URL, _ to: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = [from.path, to.path]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = FileHandle.nullDevice
        do { try proc.run() } catch {
            throw Failure(message: "跑不了 /usr/bin/ditto：\(error.localizedDescription)")
        }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(message: "ditto 失败（退出码 \(proc.terminationStatus)）：\(text)")
        }
    }

    // MARK: - ④ package.json

    /// 必须在 `bundles` 里、且必须排在最前的两层 dsh in-box bundle。
    ///
    /// **`dsh-web-app` 得手动列**：dsh 的 `PROFILE_TEMPLATES` 只给 `web` 与
    /// `headless` 配了模板，别的 profile 初始化时只拿到 `dsh-base`，web 那一层
    /// 不会自己出现。两个都是 in-box 的，不用装、也不用列进 dependencies。
    private static let inBoxBundles = ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]

    /// - Returns: 这次有没有真的改写文件。
    private static func updateManifest(dir: URL, packages: [Package], profile: String) throws -> Bool {
        let url = dir.appendingPathComponent("package.json")
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            throw Failure(message: "读不了 \(url.path)：\(error.localizedDescription)")
        }
        var doc: OrderedJSON
        do { doc = try OrderedJSON.parse(text) } catch {
            throw Failure(message: "\(url.path) 不是合法 JSON：\(error.localizedDescription)。"
                          + "自举不猜你的意图，先修好它。")
        }
        guard case .object = doc else {
            throw Failure(message: "\(url.path) 的顶层不是对象")
        }

        // —— dependencies：只动我们那几个 key，其余保序原样。
        var deps = doc.child("dependencies") ?? .object([])
        guard case .object = deps else {
            throw Failure(message: "\(url.path) 的 dependencies 不是对象")
        }
        let mine = Set(packages.map(\.name))
        for pkg in packages {
            deps.setChild(pkg.name, .string("link:./\(mirrorDirName)/\(pkg.dir)"))
        }
        // 清理：上一版留下、这一版不再有的包。判据是"link 目标在 .surfclam/ 之内"
        // ——用户自己的依赖天然不满足它，不受影响。
        if case .object(let entries) = deps {
            for (key, value) in entries where !mine.contains(key) {
                if case .string(let spec) = value, isMirrorLink(spec) {
                    deps.removeChild(key)
                    log("镜像里已没有 \(key)，从 dependencies 里摘掉")
                }
            }
        }
        doc.setChild("dependencies", deps)

        // —— dsh.profile.bundles：那三行补齐并排在最前。
        let umbrella = packages.first(where: \.isBundle)!.name
        let required = inBoxBundles + [umbrella]
        var dsh = doc.child("dsh") ?? .object([])
        var prof = dsh.child("profile") ?? .object([])
        var existing: [String] = []
        if case .array(let items) = (prof.child("bundles") ?? .array([])) {
            existing = items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        // **被编排的插件绝不能出现在 bundles 里**：它们已经没有 dsh.bundle 声明，
        // 列上去会让 loadProfile 当场 fails loud（"列为 bundle 却没有声明"）。
        let drop = Set(required).union(mine)
        let bundles = required + existing.filter { !drop.contains($0) }
        prof.setChild("bundles", .array(bundles.map { .string($0) }))
        dsh.setChild("profile", prof)
        doc.setChild("dsh", dsh)

        let next = doc.serialized(indent: detectIndent(text)) + "\n"
        guard next != text else { return false }
        try write(next, to: url)
        log("已更新 \(url.path)（profile \(profile)：\(packages.count) 行依赖 + \(bundles.count) 行 bundles）")
        return true
    }

    /// 沿用文件本来的缩进（dsh 与 pnpm 都写两个空格，但别假设）。
    private static func detectIndent(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let spaces = line.prefix { $0 == " " }
            if !spaces.isEmpty, line.count > spaces.count { return String(spaces) }
            let tabs = line.prefix { $0 == "\t" }
            if !tabs.isEmpty, line.count > tabs.count { return String(tabs) }
        }
        return "  "
    }

    // MARK: - ⑤ 符号链接

    /// - Returns: 这次动了几条。
    private static func updateLinks(dir: URL, packages: [Package]) throws -> Int {
        let fm = FileManager.default
        let modules = dir.appendingPathComponent("node_modules", isDirectory: true)
        var changed = 0
        var scopes = Set<String>()

        for pkg in packages {
            let parts = pkg.name.split(separator: "/").map(String.init)
            let link = parts.reduce(modules) { $0.appendingPathComponent($1) }
            if parts.count > 1 { scopes.insert(parts[0]) }
            try? fm.createDirectory(at: link.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            // 相对目标：从**链接所在目录**数回 profile 根，再进镜像。
            // 链接在 profile 之下的深度 = `node_modules` 一层 + scope 那几层
            // = `parts.count`。`<profile>/node_modules/@wenbo/x` → `../../.surfclam/x`。
            // **多数一层是个安静的错**：链接指到 `profiles/` 去，`ls` 看着正常，
            // 而 node 解析不到 → `dsh plugin add` 的 reconcile 顺手把解析不到的
            // 伞包从 `bundles` 里摘掉（实测踩过）。
            let up = String(repeating: "../", count: parts.count)
            let target = "\(up)\(mirrorDirName)/\(pkg.dir)"
            if try ensureSymlink(at: link, to: target) { changed += 1 }
        }

        // 清理：上一版留下、这一版不再有的包。同样只认"指进镜像"的那些。
        let mine = Set(packages.map(\.dir))
        for scope in scopes.sorted() {
            let scopeDir = modules.appendingPathComponent(scope)
            for entry in (try? fm.contentsOfDirectory(atPath: scopeDir.path))?.sorted() ?? [] {
                let link = scopeDir.appendingPathComponent(entry)
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
                      dest.contains("/\(mirrorDirName)/"),
                      !mine.contains((dest as NSString).lastPathComponent) else { continue }
                try? fm.removeItem(at: link)
                changed += 1
                log("镜像里已没有 \(scope)/\(entry)，摘掉那条链接")
            }
        }
        return changed
    }

    /// 照 dsh 的 `ensureSymlink`：错的/悬空的换掉，**真目录当场抛**
    /// （那是别人的东西，不该由我们静默删）。
    /// - Returns: 这次有没有动过它。
    private static func ensureSymlink(at link: URL, to target: String) throws -> Bool {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: link.path)
        if let type = attrs?[.type] as? FileAttributeType {
            if type == .typeSymbolicLink {
                if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target { return false }
                try? fm.removeItem(at: link)
            } else {
                throw Failure(message: "\(link.path) 存在但不是符号链接。"
                              + "自举不动它——先手工移开，或删掉整个 profile 重来。")
            }
        }
        do {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        } catch {
            throw Failure(message: "建不了链接 \(link.path) → \(target)：\(error.localizedDescription)")
        }
        return true
    }

    // MARK: - 杂项

    private static func write(_ text: String, to url: URL) throws {
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            throw Failure(message: "写不了 \(url.path)：\(error.localizedDescription)")
        }
    }

    private static func log(_ message: String) {
        Log.write(message, to: ClamPaths.logURL, tag: "bootstrap")
    }
}

// MARK: - 保序 JSON

/// **保序**的 JSON 表示。`JSONSerialization` 的字典是无序的，拿它读-改-写
/// `package.json` 会把用户 `dsh plugin add` 进来的那些行重新排一遍——那正是
/// 计划 §3.5 纪律 1 明令禁止的"整体重写"。数字保留原始字面量（不经 Double
/// 往返，`1e10` / `0.30` 这类写法原样留着）。
enum OrderedJSON {
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    struct SyntaxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: 访问

    func child(_ key: String) -> OrderedJSON? {
        guard case .object(let entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }

    /// 有就改（**保持原位**），没有就追加在末尾。
    mutating func setChild(_ key: String, _ value: OrderedJSON) {
        guard case .object(var entries) = self else { return }
        if let i = entries.firstIndex(where: { $0.key == key }) { entries[i].value = value }
        else { entries.append((key, value)) }
        self = .object(entries)
    }

    mutating func removeChild(_ key: String) {
        guard case .object(var entries) = self else { return }
        entries.removeAll { $0.key == key }
        self = .object(entries)
    }

    // MARK: 解析

    static func parse(_ text: String) throws -> OrderedJSON {
        var scanner = Scanner(Array(text.unicodeScalars))
        let value = try scanner.value()
        scanner.skipWhitespace()
        guard scanner.atEnd else { throw SyntaxError(message: "第 \(scanner.index) 个字符之后还有多余内容") }
        return value
    }

    private struct Scanner {
        let s: [Unicode.Scalar]
        var index = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { index >= s.count }
        private var peek: Unicode.Scalar? { atEnd ? nil : s[index] }

        mutating func skipWhitespace() {
            while let c = peek, c == " " || c == "\n" || c == "\t" || c == "\r" { index += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            skipWhitespace()
            guard let c = peek else { throw SyntaxError(message: "内容意外结束") }
            switch c {
            case "{": return try object()
            case "[": return try array()
            case "\"": return .string(try string())
            case "t": try literal("true"); return .bool(true)
            case "f": try literal("false"); return .bool(false)
            case "n": try literal("null"); return .null
            default: return .number(try number())
            }
        }

        private mutating func literal(_ word: String) throws {
            for ch in word.unicodeScalars {
                guard peek == ch else { throw SyntaxError(message: "第 \(index) 个字符处期望 \(word)") }
                index += 1
            }
        }

        private mutating func object() throws -> OrderedJSON {
            index += 1  // {
            var entries: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if peek == "}" { index += 1; return .object(entries) }
            while true {
                skipWhitespace()
                guard peek == "\"" else { throw SyntaxError(message: "第 \(index) 个字符处期望键名") }
                let key = try string()
                skipWhitespace()
                guard peek == ":" else { throw SyntaxError(message: "第 \(index) 个字符处期望 :") }
                index += 1
                entries.append((key, try value()))
                skipWhitespace()
                if peek == "," { index += 1; continue }
                if peek == "}" { index += 1; return .object(entries) }
                throw SyntaxError(message: "第 \(index) 个字符处期望 , 或 }")
            }
        }

        private mutating func array() throws -> OrderedJSON {
            index += 1  // [
            var items: [OrderedJSON] = []
            skipWhitespace()
            if peek == "]" { index += 1; return .array(items) }
            while true {
                items.append(try value())
                skipWhitespace()
                if peek == "," { index += 1; continue }
                if peek == "]" { index += 1; return .array(items) }
                throw SyntaxError(message: "第 \(index) 个字符处期望 , 或 ]")
            }
        }

        private mutating func string() throws -> String {
            index += 1  // "
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek else { throw SyntaxError(message: "字符串没有收尾") }
                index += 1
                if c == "\"" { return String(out) }
                guard c == "\\" else { out.append(c); continue }
                guard let esc = peek else { throw SyntaxError(message: "转义没有收尾") }
                index += 1
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append(Unicode.Scalar(8))
                case "f": out.append(Unicode.Scalar(12))
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    let unit = try hex4()
                    // 代理对：JSON 里的星文字符是两段 \u。
                    if unit >= 0xD800, unit <= 0xDBFF, peek == "\\", index + 1 < s.count, s[index + 1] == "u" {
                        index += 2
                        let low = try hex4()
                        let scalar = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(low - 0xDC00)
                        out.append(Unicode.Scalar(scalar) ?? "\u{FFFD}")
                    } else {
                        out.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                    }
                default: throw SyntaxError(message: "第 \(index) 个字符处是无法识别的转义")
                }
            }
        }

        private mutating func hex4() throws -> UInt16 {
            var v: UInt16 = 0
            for _ in 0..<4 {
                guard let c = peek, let d = Character(c).hexDigitValue else {
                    throw SyntaxError(message: "第 \(index) 个字符处期望 4 位十六进制")
                }
                v = v << 4 | UInt16(d)
                index += 1
            }
            return v
        }

        private mutating func number() throws -> String {
            let start = index
            while let c = peek,
                  (c >= "0" && c <= "9") || c == "-" || c == "+" || c == "." || c == "e" || c == "E" {
                index += 1
            }
            guard index > start else { throw SyntaxError(message: "第 \(index) 个字符处期望一个值") }
            return String(String.UnicodeScalarView(s[start..<index]))
        }
    }

    // MARK: 序列化

    /// 与 `JSON.stringify(x, undefined, indent)` 逐字同形（dsh 与 pnpm 写
    /// `package.json` 用的就是它）：空对象/空数组塌成 `{}` / `[]`，
    /// 非 ASCII 原样留（不转 `\uXXXX`）。
    func serialized(indent: String = "  ") -> String {
        render(indent: indent, depth: 0)
    }

    private func render(indent: String, depth: Int) -> String {
        let pad = String(repeating: indent, count: depth + 1)
        let closePad = String(repeating: indent, count: depth)
        switch self {
        case .object(let entries):
            if entries.isEmpty { return "{}" }
            let body = entries.map {
                "\(pad)\(Self.quote($0.key)): \($0.value.render(indent: indent, depth: depth + 1))"
            }.joined(separator: ",\n")
            return "{\n\(body)\n\(closePad)}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items.map { "\(pad)\($0.render(indent: indent, depth: depth + 1))" }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(closePad)]"
        case .string(let s): return Self.quote(s)
        case .number(let raw): return raw
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
