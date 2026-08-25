/**
 * dash-bridge —— 唯一的特权插件（阶段二计划 §5）。
 *
 * 它做三件事，一件不多：
 *
 *   1. **Swift 载荷登记表**：`ctx.provide('dashBridge', api)`，各插件经
 *      `createSwiftPlugin`（见 `./plugin.js`）把自己的 `swift/` 目录登记进来。
 *   2. **一条 WebSocket**（`/dash/bridge`，与 dsh 同端口）：壳连上来拉 snapshot、
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
 * @module dash-bridge
 */
import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";
import z from "@deepseek-ai/schemastery";
import { WebSocketServer } from "ws";

export const name = "dash-bridge";

export const inject = ["webServer"];

export const Config = z.object({
	path: z.string().default("/dash/bridge")
		.description("WebSocket 升级路径（与 dsh 同端口）。改这里必须同步壳侧的 endpoint 发现文件。"),
	pollIntervalMs: z.number().step(1).min(100).default(500)
		.description("盯各插件 swift/ 目录的轮询间隔，与 dsh-client-hmr 同款做法。"),
});

/** 桥协议版本（计划 §5.4）。壳侧 `BridgeProtocol.version` 必须一致。 */
const PROTOCOL_VERSION = 1;

/** 只收这些扩展名进 snapshot——插件的 swift/ 目录里放别的都不算源码。 */
const SOURCE_EXTENSIONS = [".swift"];

/** 轮询时跳过的目录名。 */
const SKIP_DIRS = new Set([".git", ".build", "build", "DerivedData", ".DS_Store", "node_modules"]);

export function apply(ctx, config) {
	const logger = reporter(ctx.logger("dash-bridge"));
	/** @type {Map<string, Registration>} 插件名 → 登记项 */
	const registry = new Map();
	/** @type {Set<Client>} 已握手的壳客户端 */
	const clients = new Set();
	/** 登记表版本：全表 hash 的短前缀 + 单调计数，方便人眼比对。 */
	let version = 0;
	let tableHash = "";

	// ---- 登记表 API（各插件经 createSwiftPlugin 调用） ----
	ctx.provide("dashBridge", {
		protocolVersion: PROTOCOL_VERSION,
		register(entry) {
			if (registry.has(entry.plugin)) {
				logger.warn(`插件 ${entry.plugin} 重复登记 Swift 载荷，后者覆盖前者。`);
			}
			const record = {
				plugin: entry.plugin,
				module: moduleName(entry.plugin),
				swiftDir: entry.swiftDir,
				swiftDeps: entry.swiftDeps ?? [],
				schemaVersion: entry.schemaVersion ?? 1,
				expose: entry.expose ?? {},
				signature: undefined,
				files: undefined,
			};
			registry.set(entry.plugin, record);
			logger.info(`登记 Swift 载荷：${entry.plugin} → ${entry.swiftDir}`
				+ (record.swiftDeps.length ? `（依赖 ${record.swiftDeps.join(", ")}）` : ""));
			rescan("登记");
			return {
				/** 把数据推给这个插件的 Swift 半身（下行 push 帧）。 */
				push(channel, payload) {
					broadcast({ type: "push", plugin: entry.plugin, channel, payload });
				},
				dispose() {
					if (registry.get(entry.plugin) === record) {
						registry.delete(entry.plugin);
						rescan("撤销登记");
					}
				},
			};
		},
	});

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
	}), "dash-bridge WebSocket 升级路由");

	ctx.effect(() => () => {
		for (const client of clients) { try { client.ws.close(); } catch { /* 已断 */ } }
		clients.clear();
		wss.close();
	}, "dash-bridge 关闭全部连接");

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
				contentHash: record.contentHash,
				schemaVersion: record.schemaVersion,
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
		if (!dirty) return false;

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
			record.contentHash = hash.digest("hex");
		}

		const next = createHash("sha256");
		for (const record of topological()) next.update(`${record.plugin}=${record.contentHash}\0`);
		const digest = next.digest("hex");
		if (digest === tableHash) return false;

		tableHash = digest;
		version += 1;
		logger.info(`Swift 载荷登记表 v${version}（${reason}）：`
			+ topological().map((r) => `${r.plugin}@${r.contentHash.slice(0, 8)}`).join(" "));
		broadcast({ type: "changed", version });
		return true;
	}

	const timer = setInterval(() => rescan("轮询"), config.pollIntervalMs);
	timer.unref?.();
	ctx.effect(() => () => clearInterval(timer), "dash-bridge swift/ 轮询");

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

/** `dash-sidebar` → `DashSidebar`。Swift module 名的唯一出处。 */
function moduleName(plugin) {
	return plugin.split(/[-_]/).filter(Boolean)
		.map((part) => part[0].toUpperCase() + part.slice(1))
		.join("");
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
 * 桥的进度要给蹲在终端的人看，所以照 dash-app 的做法两边都喂。
 */
function reporter(logger) {
	const emit = (level, message) => {
		logger[level](message);
		process.stderr.write(`dash-bridge: ${message}\n`);
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
