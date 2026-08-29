/**
 * clam-bridge —— 唯一的特权插件（阶段二计划 §5）。
 *
 * 它做三件事，一件不多：
 *
 *   1. **Swift 载荷登记表**：`ctx.provide('clamBridge', api)`，各插件经
 *      `createSwiftPlugin`（见 `./plugin.js`）把自己的 `swift/` 目录登记进来。
 *      同一张表还捎带插件的**命令声明**（菜单项 + 默认键位，形状见 `./plugin.js`）：
 *      桥不解释它，只透传给两个读者——壳（snapshot）与 clam-app（`commands.list()`）。
 *   2. **一条 WebSocket**（`/clam/bridge`，与 dsh 同端口）：壳连上来拉 snapshot、
 *      回报编译结果、收发插件与其 TS 半身之间的信封消息。
 *   3. **盯文件**：500ms statSync 轮询各 `swift/` 目录。node 半边在 web bundle 下
 *      没有 HMR（官方 disable），所以 Swift 源码的热循环不能指望它——桥常驻、
 *      自己看着文件变，变了就 bump 版本广播 `changed`，TS 半身完全不用重载。
 *
 * **级联重编是硬约束**（M2 断言 6 实测，见 `docs/native-abi.md` §4）：上游插件源码
 * 变了而下游没重编时，下游**不崩、不报错**，只是静默绑在旧代——UI 上毫无征兆的
 * 认知分裂。这里的做法是把上游的 contentHash 折进下游的 contentHash：
 * 上游一变，下游的 hash 必然跟着变，壳那边"hash 没变就不重编"的判断自动就带上了
 * 级联，不需要额外的传播逻辑。
 *
 * 绝不往 session 日志写任何自定义事件（计划 §0.5-6：0.1.1-rc.2 会导致
 * SessionFormatUnsupportedError、会话再也读不回来）。桥的流量全走自己这条 WS。
 *
 * @module clam-bridge
 */
import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";
import z from "@deepseek-ai/schemastery";
import { WebSocketServer } from "ws";
import { environmentLocale } from "./locale.js";

export const name = "clam-bridge";

export const inject = ["webServer"];

/**
 * 这两条 description 用哪门语言（计划 §7）。
 *
 * **只到得了环境推导那一级**：`Config` 是模块级常量，cordis 在实例化插件时就要
 * 读它，那一刻没有任何 ctx，`ctx.settings.get("locale")` 无从谈起。决议链因此
 * 少了最上面一级，剩下的与别处逐字同源（`./locale.js`）。dsh 自己的
 * registry-held text 干脆一门语言都不翻，这已经是更进一步。
 */
const LOCALE = environmentLocale();

export const Config = z.object({
	path: z.string().default("/clam/bridge")
		.description(LOCALE === "zh"
			? "WebSocket 升级路径（与 dsh 同端口）。clam-app 经 clamBridge.path 取这个值写进 endpoint 发现文件，改这里无需再同步别处。"
			: "WebSocket upgrade path, served on the dsh port. clam-app reads it back through clamBridge.path and writes it into the endpoint discovery file, so changing it here needs no matching change elsewhere."),
	pollIntervalMs: z.number().step(1).min(100).default(500)
		.description(LOCALE === "zh"
			? "盯各插件 swift/ 目录的轮询间隔，与 dsh-client-hmr 同款做法。"
			: "How often to poll each plugin’s swift/ directory, the same approach dsh-client-hmr takes."),
});

/** 桥协议版本（计划 §5.4）。壳侧 `BridgeProtocol.version` 必须一致。 */
const PROTOCOL_VERSION = 1;

/** 只收这些扩展名进 snapshot——插件的 swift/ 目录里放别的都不算源码。 */
const SOURCE_EXTENSIONS = [".swift"];

/**
 * `moduleName()` 的结果必须是一个合法的 Swift 标识符。
 *
 * 不合法时的失败模式是**最坏的那一种**：dsh 照常起、HTTP 200，登记也"成功"了，
 * 一直到壳去 `swiftc -module-name @wenbo/clamFoo` 才炸，而那条错误落在壳的日志里、
 * 长得像编译器的毛病。所以在登记这一刻就拦住（见 `register`）。
 */
const MODULE_NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

/** 轮询时跳过的目录名。 */
const SKIP_DIRS = new Set([".git", ".build", "build", "DerivedData", ".DS_Store", "node_modules"]);

export function apply(ctx, config) {
	const logger = reporter(ctx.logger("clam-bridge"));
	/** @type {Map<string, Registration>} 插件名 → 登记项 */
	const registry = new Map();
	/** @type {Set<Client>} 已握手的壳客户端 */
	const clients = new Set();
	/** @type {Set<() => void>} 登记表里命令声明变动时要通知的人（眼下只有 clam-app）。 */
	const commandWatchers = new Set();
	/** clam-app 登记的"壳请求重启自己"处理器（§7.5 v1）。 */
	let appRestartHandler;
	/** 登记表版本：全表 hash 的短前缀 + 单调计数，方便人眼比对。 */
	let version = 0;
	let tableHash = "";

	// ---- 登记表 API（各插件经 createSwiftPlugin 调用） ----
	ctx.provide("clamBridge", {
		protocolVersion: PROTOCOL_VERSION,
		/**
		 * 本桥实际挂载的 WS 路径。**这是该路径的唯一真相**——挂 WS 的是这里，
		 * 而 `path` 又是用户可覆写的配置项。clam-app 取它写进 endpoint 发现文件
		 * 与 `--clam-bridge-path`，壳因此永远连得上，不管用户把它改成什么。
		 */
		path: config.path,

		/**
		 * 命令声明的汇总视图（形状见 `./plugin.js` 的 CommandDeclaration）。
		 *
		 * 壳走 snapshot 的 `commands` 字段拿同一份；这条 API 是给 **clam-app** 的
		 * ——它要按这张表现拼 `clam-shortcuts` 设置 ns 的 schema，而设置面不过桥。
		 * 两个读者一份声明，"两张表逐字一致"那条无人校验的纪律就此消失。
		 */
		commands: {
			/** 按登记顺序（插件的挂载顺序）铺平；同 id 由多家声明时先登记的在前。 */
			list() {
				return [...registry.values()].flatMap((record) =>
					record.commands.map((command) => ({ ...command, owner: record.plugin })));
			},
			/** 登记表增删时回调；返回撤销函数。**不带载荷**——回调自己再 `list()` 一次。 */
			subscribe(fn) {
				commandWatchers.add(fn);
				return () => commandWatchers.delete(fn);
			},
		},

		/**
		 * 登记一份 Swift 载荷。**这里一律 fails loud，不做任何补救。**
		 *
		 * 登记是 dsh 启动时发生一次的事，而下面三种错的失败模式全是同一副样子：
		 * dsh 照常起、HTTP 200、终端一片祥和，只是那个插件的原生半边**静默不存在**
		 * （或者更糟：两份登记互相覆盖，界面上少一块，日志里什么都没有）。
		 * 抛出去的话 cordis 会在加载插件时就把它顶到脸上，附带插件名——
		 * 这是唯一能让作者当场看见的时机。
		 */
		register(entry) {
			// Swift module 名不是"顺手推的"，它是编译参数：不合法就等到壳去
			// `swiftc -module-name` 那一刻才炸，而错误落在壳的日志里、看着像编译器的毛病。
			const module = typeof entry.plugin === "string" ? moduleName(entry.plugin) : "";
			if (!MODULE_NAME_RE.test(module)) {
				throw new Error(`clam-bridge：插件 name ${JSON.stringify(entry.plugin)} 推不出合法的 `
					+ `Swift module 名（算出来是 ${JSON.stringify(module)}）。`
					+ `name 要用 kebab-case 的裸名（如 clam-sidebar → ClamSidebar），`
					+ `别拿 scoped 包名（@wenbo/clam-sidebar）当 name。`);
			}
			if (registry.has(entry.plugin)) {
				// 覆盖是**最坏的兼容**：两个插件重名时后者把前者的 swiftDir 顶掉，
				// 界面上少的那一块与日志里的 warn 隔着十万八千里。
				throw new Error(`clam-bridge：插件 name "${entry.plugin}" 重复登记 Swift 载荷。`
					+ `每个插件的 name 必须全局唯一——同一个插件被挂载两次的话，`
					+ `检查编排表（cordis.patch.yml）里是不是列了两行。`);
			}
			const dirStats = typeof entry.swiftDir === "string"
				? statSync(entry.swiftDir, { throwIfNoEntry: false })
				: undefined;
			if (dirStats?.isDirectory() !== true) {
				throw new Error(`clam-bridge：插件 "${entry.plugin}" 的 swiftDir 不是一个目录：`
					+ `${JSON.stringify(entry.swiftDir)}。它一般是 `
					+ `\`new URL("../swift", import.meta.url)\` 算出来的，`
					+ `检查 package.json 的 files 白名单里有没有 "swift"。`);
			}
			if (Object.keys(scanDir(entry.swiftDir).files).length === 0) {
				throw new Error(`clam-bridge：插件 "${entry.plugin}" 的 swiftDir 里一个 .swift 文件都没有：`
					+ `${entry.swiftDir}。空载荷登记上来只会让壳编出一个空 module——`
					+ `没有 Swift 半边的插件不该调 createSwiftPlugin。`);
			}
			const record = {
				plugin: entry.plugin,
				module,
				swiftDir: entry.swiftDir,
				swiftDeps: entry.swiftDeps ?? [],
				// 排序落库：声明顺序不该影响 contentHash，也不该影响编译参数。
				sharedModules: [...new Set(entry.sharedModules ?? [])].sort(),
				schemaVersion: entry.schemaVersion ?? 1,
				// 命令声明只是**透传的数据**：桥不解释它，也不校验它（形状的文档在
				// `./plugin.js` 的 CommandDeclaration）。**它刻意不进 contentHash**
				// ——改一句菜单文案不该让 Swift 半边全量重编。
				commands: Array.isArray(entry.commands) ? entry.commands : [],
				expose: entry.expose ?? {},
				signature: undefined,
				files: undefined,
			};
			registry.set(entry.plugin, record);
			logger.info(`登记 Swift 载荷：${entry.plugin} → ${entry.swiftDir}`
				+ (record.swiftDeps.length ? `（依赖 ${record.swiftDeps.join(", ")}）` : "")
				+ (record.sharedModules.length ? `（共享 module ${record.sharedModules.join(", ")}）` : ""));
			rescan("登记");
			notifyCommandWatchers();
			return {
				/** 把数据推给这个插件的 Swift 半身（下行 push 帧）。 */
				push(channel, payload) {
					broadcast({ type: "push", plugin: entry.plugin, channel, payload });
				},
				dispose() {
					if (registry.get(entry.plugin) === record) {
						registry.delete(entry.plugin);
						rescan("撤销登记");
						notifyCommandWatchers();
					}
				},
			};
		},

		/**
		 * clam-app 专用通道（§7.5 v1）。壳的构建不是插件热替换那个档位——
		 * 它要重启进程，所以走一条自己的帧，不混进 push/invoke 的插件信封。
		 */
		app: {
			/**
			 * 播报壳构建进度：`building` / `ready` / `failed`。
			 *
			 * **只播给此刻连着的壳，不为后来者留底。** "你手上的壳过期了"这句话
			 * 只对构建发生时正在运行的那个进程成立；新连上来的壳跑的必然是磁盘上
			 * 最新的产物，补发给它就是撒谎——实测会让 `restartOnRebuild` 的壳
			 * 退出、重拉、握手、又收到同一句话，无限重启。
			 */
			announce(status, detail = {}) {
				broadcast({ type: "app-build", status, ...detail });
			},
			/** 登记"壳请求重启自己"的处理器；返回撤销函数。 */
			onRestartRequest(handler) {
				appRestartHandler = handler;
				return () => { if (appRestartHandler === handler) appRestartHandler = undefined; };
			},
		},
	});

	/**
	 * 通知命令声明的读者。**一个订阅者抛错不许连累别人**，也不许把登记打断
	 * ——它是在 `register` 里同步调用的。
	 */
	function notifyCommandWatchers() {
		for (const fn of commandWatchers) {
			try {
				fn();
			} catch (error) {
				logger.warn(`命令声明订阅者抛错：${errorText(error)}`);
			}
		}
	}

	// ---- WebSocket ----
	const wss = new WebSocketServer({ noServer: true });

	ctx.effect(() => ctx.webServer.registerUpgrade({
		path: config.path,
		handler: (req, socket, head) => {
			// 自注册路由的信任栅栏要自己做——`/api` 那道是 dsh-client-connection
			// 自己加的，不是 webServer 的（计划 §1.5）。仿 api-request-trust：
			// Host 必须是 loopback。
			if (!isLoopbackRequest(req)) {
				socket.destroy();
				return;
			}
			wss.handleUpgrade(req, socket, head, (ws) => attach(ws));
		},
	}), "clam-bridge WebSocket 升级路由");

	ctx.effect(() => () => {
		for (const client of clients) { try { client.ws.close(); } catch { /* 已断 */ } }
		clients.clear();
		wss.close();
	}, "clam-bridge 关闭全部连接");

	function attach(ws) {
		const client = { ws, id: undefined, ready: false };
		clients.add(client);
		ws.on("message", (data) => {
			let frame;
			try {
				frame = JSON.parse(String(data));
			} catch {
				return; // 未知/坏帧一律忽略不崩（协议向前兼容）
			}
			handleFrame(client, frame);
		});
		ws.on("close", () => { clients.delete(client); });
		ws.on("error", () => { clients.delete(client); });
	}

	function handleFrame(client, frame) {
		switch (frame?.type) {
			case "hello":
				client.id = typeof frame.clientId === "string" ? frame.clientId : "?";
				client.ready = true;
				send(client, {
					type: "hello",
					protocolVersion: PROTOCOL_VERSION,
					registryVersion: version,
				});
				logger.info(`壳已连接（clientId ${client.id}，protocol ${frame.protocolVersion}）`);
				break;

			case "snapshot":
				rescan("snapshot 请求");
				send(client, snapshotFrame());
				break;

			case "compile-result": {
				const ok = frame.ok === true;
				const line = `${frame.plugin} @ ${String(frame.contentHash ?? "?").slice(0, 12)}`;
				if (ok) logger.info(`编译成功：${line}`);
				else logger.error(`编译失败：${line}\n${tail(String(frame.log ?? ""), 20)}`);
				break;
			}

			case "invoke": {
				const record = registry.get(frame.plugin);
				const handler = record?.expose?.[frame.action];
				if (typeof handler !== "function") {
					logger.warn(`插件 ${frame.plugin} 没有暴露动作 ${frame.action}，忽略。`);
					return;
				}
				Promise.resolve()
					.then(() => handler(frame.payload ?? {}))
					.catch((error) => logger.warn(
						`${frame.plugin}.${frame.action} 抛错：${errorText(error)}`));
				break;
			}

			case "app-restart":
				// 壳即将自己退出，让 clam-app 等它死透再拉起新产物（§7.5 v1）。
				if (appRestartHandler === undefined) {
					logger.warn("壳请求重启自己，但没有 clam-app 接管——它退出后不会被拉回来。");
					return;
				}
				logger.info("壳请求重启自己 —— 交给 clam-app 等待并重拉。");
				Promise.resolve().then(() => appRestartHandler())
					.catch((error) => logger.warn(`重拉壳失败：${errorText(error)}`));
				break;

			case "restart-dsh":
				// 前台跑 dsh 时退出即止，由用户在终端重启（计划 §10-R10）。
				logger.info("壳请求重启 dsh —— 退出当前进程。");
				try { ctx.appExit?.(0); } catch (error) { logger.warn(`appExit 不可用：${errorText(error)}`); }
				break;

			default:
				break; // 未知帧忽略
		}
	}

	function send(client, frame) {
		try { client.ws.send(JSON.stringify(frame)); } catch { /* 断了就断了 */ }
	}

	function broadcast(frame) {
		const text = JSON.stringify(frame);
		for (const client of clients) {
			try { client.ws.send(text); } catch { /* 断了就断了 */ }
		}
	}

	function snapshotFrame() {
		return {
			type: "snapshot-result",
			version,
			plugins: topological().map((record) => ({
				name: record.plugin,
				module: record.module,
				files: record.files ?? {},
				swiftDeps: record.swiftDeps,
				sharedModules: record.sharedModules,
				contentHash: record.contentHash,
				schemaVersion: record.schemaVersion,
				commands: record.commands,
			})),
		};
	}

	// ---- 盯文件 ----

	/**
	 * 重扫全部登记项。签名（路径+mtime+size）没变就不读文件内容；
	 * 变了才读内容算 hash——与 dsh-client-hmr 同款的廉价轮询。
	 * @returns 是否有实质变化
	 */
	function rescan(reason) {
		let dirty = false;
		for (const record of registry.values()) {
			const scan = scanDir(record.swiftDir);
			if (scan.signature === record.signature) continue;
			record.signature = scan.signature;
			record.files = scan.files;
			dirty = true;
		}

		if (dirty) {
			// contentHash 折进依赖的 contentHash：上游一变，下游必然跟着变。
			// 这就是"级联重编"在数据结构层面的落实，壳侧不需要再做传播。
			for (const record of topological()) {
				const hash = createHash("sha256");
				hash.update(record.module);
				hash.update("\0");
				for (const [path, content] of Object.entries(record.files ?? {}).sort(byKey)) {
					hash.update(path);
					hash.update("\0");
					hash.update(content);
					hash.update("\0");
				}
				for (const dep of record.swiftDeps) {
					hash.update(`dep:${dep}=${registry.get(dep)?.contentHash ?? "missing"}\0`);
				}
				// 共享 module 的**声明**进 hash（内容不进——桥看不见 bundle 里的
				// .swiftinterface，那部分由壳的 CompilerService 折进去）。
				// 加进来是因为改声明就改了编译参数，必须重编。
				for (const module of record.sharedModules) hash.update(`shared:${module}\0`);
				record.contentHash = hash.digest("hex");
			}
		}

		// 表 hash **每轮都算，不只在源码变了的时候**：它盖住的是整份 snapshot，
		// 而 snapshot 里除了 contentHash 还有**谁在表上**和**各家的命令声明**。
		// 命令声明刻意不进 contentHash（改一句菜单文案不该让 Swift 半边重编），
		// 可它照样要送到壳那边去建菜单；不折进这里的话，"只改了命令声明"和
		// "某个插件退场"都不会 bump 版本、不会广播 changed，壳的菜单就停在上一版，
		// 而且**不报错**——只是少了一项，像是声明没写对。
		const next = createHash("sha256");
		for (const record of topological()) {
			next.update(`${record.plugin}=${record.contentHash ?? "?"}\0`);
			next.update(`commands=${commandsDigest(record.commands)}\0`);
		}
		const digest = next.digest("hex");
		if (digest === tableHash) return false;

		tableHash = digest;
		version += 1;
		logger.info(`Swift 载荷登记表 v${version}（${reason}）：`
			+ topological().map((r) => `${r.plugin}@${r.contentHash?.slice(0, 8) ?? "?"}`).join(" "));
		broadcast({ type: "changed", version });
		return true;
	}

	const timer = setInterval(() => rescan("轮询"), config.pollIntervalMs);
	timer.unref?.();
	ctx.effect(() => () => clearInterval(timer), "clam-bridge swift/ 轮询");

	/**
	 * 拓扑序（依赖在前）。它约束的是**编译顺序**与 **activate 顺序**——
	 * dlopen 本身不需要拓扑序（M2 实测：@rpath 让 dyld 自动带起上游）。
	 * 环或缺失依赖：把该插件排到最后并记一条日志，不抛异常。
	 */
	function topological() {
		const out = [];
		const state = new Map(); // 插件名 → "visiting" | "done"
		const visit = (plugin) => {
			const record = registry.get(plugin);
			if (record === undefined) return;
			const mark = state.get(plugin);
			if (mark === "done") return;
			if (mark === "visiting") {
				logger.warn(`Swift 依赖成环，涉及 ${plugin}；按登记顺序退化处理。`);
				return;
			}
			state.set(plugin, "visiting");
			for (const dep of record.swiftDeps) visit(dep);
			state.set(plugin, "done");
			out.push(record);
		};
		for (const plugin of registry.keys()) visit(plugin);
		return out;
	}
}

// ---------------------------------------------------------------- 工具

/** `clam-sidebar` → `ClamSidebar`。Swift module 名的唯一出处。 */
function moduleName(plugin) {
	return plugin.split(/[-_]/).filter(Boolean)
		.map((part) => part[0].toUpperCase() + part.slice(1))
		.join("");
}

/**
 * 命令声明的摘要，只进**表** hash，不进 contentHash（见 `rescan`）。
 *
 * 声明本身是插件写死的字面量数组，顺序稳定，`JSON.stringify` 就够稳；
 * 序列化不了的（有人往里塞了函数）退化成"每轮都不一样"也没关系——
 * 那时该修的是声明，多推几次 snapshot 不会错。
 */
function commandsDigest(commands) {
	try {
		return JSON.stringify(commands ?? []);
	} catch {
		return String(Date.now());
	}
}

/** 目录扫描：签名（廉价）+ 文件内容（签名变了才用得上）。 */
function scanDir(dir) {
	const files = {};
	const parts = [];
	for (const path of walk(dir)) {
		if (!SOURCE_EXTENSIONS.some((ext) => path.endsWith(ext))) continue;
		const rel = relative(dir, path).split(sep).join("/");
		let stats;
		try {
			stats = statSync(path);
		} catch {
			continue; // 扫描途中被删：当它不存在
		}
		parts.push(`${rel}:${stats.mtimeMs}:${stats.size}`);
		try {
			files[rel] = readFileSync(path, "utf8");
		} catch {
			continue;
		}
	}
	return { signature: parts.sort().join("|"), files };
}

function* walk(path) {
	let stats;
	try {
		stats = statSync(path);
	} catch {
		return;
	}
	if (stats.isFile()) {
		yield path;
		return;
	}
	if (!stats.isDirectory()) return;
	for (const entry of readdirSync(path).sort()) {
		if (SKIP_DIRS.has(entry)) continue;
		yield* walk(join(path, entry));
	}
}

/** Host 头必须是 loopback（仿 dsh-client-connection 的 api-request-trust）。 */
function isLoopbackRequest(req) {
	const host = req.headers?.host;
	if (typeof host !== "string") return false;
	let hostname;
	try {
		hostname = new URL(`http://${host}`).hostname;
	} catch {
		return false;
	}
	return hostname === "127.0.0.1" || hostname === "localhost" || hostname === "::1"
		|| hostname === "[::1]";
}

/**
 * cordis logger 在 `dsh web` 下没有 exporter（计划 §1.7），消息只进环形缓冲。
 * 桥的进度要给蹲在终端的人看，所以照 clam-app 的做法两边都喂。
 */
function reporter(logger) {
	const emit = (level, message) => {
		logger[level](message);
		process.stderr.write(`clam-bridge: ${message}\n`);
	};
	return {
		info: (message) => emit("info", message),
		warn: (message) => emit("warn", message),
		error: (message) => emit("error", message),
	};
}

function byKey(a, b) {
	return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0;
}

function tail(text, lines) {
	return text.trimEnd().split("\n").slice(-lines).join("\n");
}

function errorText(error) {
	return error instanceof Error ? error.message : String(error);
}
