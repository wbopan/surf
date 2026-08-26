#!/usr/bin/env node
/**
 * dash-settings 的桥探针：不开窗口、不碰屏幕，直接当一个"壳"连上 `/dash/bridge`，
 * 把 node 半边的数据面从头验一遍。
 *
 * **为什么需要它**：设置的数据面（快照形状、单字段写入、乐观锁、redact）全都跑在
 * dsh 进程里，跟 SwiftUI 没有半点关系。用截图去验它，等于让一条 21KB 的 JSON
 * 通过一张 PNG 来汇报自己——慢、脆、还看不全。而且屏幕锁上时截图与 AX 都用不了，
 * 数据面的活儿却一点没耽误。
 *
 * **它只读不写，除非你让它写**：`--set` 才会真的改配置，而且改完立刻改回去。
 *
 * 用法：
 *   node dash-settings/tools/probe.mjs                  # 快照概览
 *   node dash-settings/tools/probe.mjs --ns shell       # 某个 ns 的详情
 *   node dash-settings/tools/probe.mjs --set            # 跑一遍写入/回滚/冲突用例
 *   node dash-settings/tools/probe.mjs --providers      # 模型页的数据
 *
 * 端点自动从 dash-app 的发现文件里找（`<AppSupport>/io.wenbo.dash/endpoints/`）。
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { WebSocket } from "ws";

const ENDPOINT_DIR = join(homedir(), "Library/Application Support/io.wenbo.dash/endpoints");

const args = process.argv.slice(2);
const wantNs = valueOf("--ns");
const doWrite = args.includes("--set");
const showProviders = args.includes("--providers");

function valueOf(flag) {
	const index = args.indexOf(flag);
	return index >= 0 ? args[index + 1] : undefined;
}

/** 发现文件里挑一个端点。多 worktree 时按 mtime 取最新的那个。 */
function findEndpoint() {
	const explicit = valueOf("--endpoint");
	if (explicit !== undefined) return explicit;
	// **按 mtime 取最新**：一个 profile 一份发现文件，而 dsh 退出时才删自己那份
	// ——上一次跑崩了的 worktree 会留下一份陈的。按目录序取等于随机挑一个死端口。
	const candidates = [];
	for (const name of readdirSync(ENDPOINT_DIR)) {
		if (!name.endsWith(".json")) continue;
		const file = join(ENDPOINT_DIR, name);
		try {
			const record = JSON.parse(readFileSync(file, "utf8"));
			const url = record.httpBase ?? record.endpoint ?? record.url;
			if (typeof url === "string") {
				candidates.push({ url, profile: record.profile ?? name, mtime: statSync(file).mtimeMs });
			}
		} catch { /* 坏文件跳过 */ }
	}
	candidates.sort((a, b) => b.mtime - a.mtime);
	if (candidates.length === 0) throw new Error(`${ENDPOINT_DIR} 里没有可用的端点，dsh 在跑吗？`);
	if (candidates.length > 1) {
		console.log(`（有 ${candidates.length} 份端点文件，取最新的 ${candidates[0].profile}；`
			+ `别的 worktree 用 --endpoint 指定）`);
	}
	return candidates[0].url;
}

const base = findEndpoint();
const wsURL = base.replace(/^http/, "ws") + "/dash/bridge";
console.log(`连接 ${wsURL}`);

const ws = new WebSocket(wsURL);
let acks = new Map();
let counter = 0;
let settings;
let providers;

/** 发一个 invoke 并等它的 ack（请求/响应在插件那一层，桥本身单向）。 */
function invoke(action, payload = {}) {
	counter += 1;
	const id = `probe-${counter}`;
	return new Promise((resolve, reject) => {
		acks.set(id, resolve);
		setTimeout(() => {
			if (acks.delete(id)) reject(new Error(`${action} 超时`));
		}, 8000);
		ws.send(JSON.stringify({
			type: "invoke", plugin: "dash-settings", action, payload: { ...payload, id },
		}));
	});
}

/**
 * 等一份**比 `seq` 新**的快照。
 *
 * 不能写成"发完动作再去等下一条推送"：node 半边是先 `pushSettings()` 再 `ack`，
 * 所以等 ack 回来时快照早就到了，再等就是等下一次——直接超时。
 * 这里改成记序号比大小，谁先到都不丢。
 */
function settingsAfter(seq) {
	if (settingsSeq > seq) return Promise.resolve(settings);
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error("没等到新快照")), 8000);
		waiters.push({ seq, resolve: (payload) => { clearTimeout(timer); resolve(payload); } });
	});
}
const waiters = [];
let settingsSeq = 0;

ws.on("open", () => {
	ws.send(JSON.stringify({ type: "hello", clientId: "dash-settings-probe", protocolVersion: 1 }));
});

ws.on("message", (data) => {
	let frame;
	try { frame = JSON.parse(String(data)); } catch { return; }
	if (frame.type !== "push" || frame.plugin !== "dash-settings") return;
	if (frame.channel === "settings") { settings = frame.payload; settingsSeq += 1; }
	if (frame.channel === "providers") providers = frame.payload;
	if (frame.channel === "ack") {
		const resolve = acks.get(frame.payload?.id);
		if (resolve) { acks.delete(frame.payload.id); resolve(frame.payload); }
	}
	if (frame.channel === "settings") {
		for (let i = waiters.length - 1; i >= 0; i -= 1) {
			if (settingsSeq > waiters[i].seq) {
				waiters[i].resolve(settings);
				waiters.splice(i, 1);
			}
		}
	}
});

ws.on("error", (error) => { console.error("桥连接失败：", error.message); process.exit(1); });

await new Promise((resolve) => ws.once("open", resolve));
await invoke("refresh");
if (settings === undefined) await settingsAfter(0);

// ---------------------------------------------------------------- 报告

console.log(`\n文档可写：${settings.writable}　有配置文件：${settings.hasDocument}`);
console.log(`命名空间 ${settings.namespaces.length} 个：`);
for (const item of settings.namespaces) {
	const fields = item.schema?.refs?.[String(item.schema.uid)]?.fields ?? [];
	const overridden = item.user === null ? 0 : Object.keys(item.user).length;
	console.log(`  ${item.ns.padEnd(24)} 字段 ${String(fields.length).padStart(2)}`
		+ `  已覆盖 ${overridden}  rev ${item.revision}`
		+ `  ${item.applies === "restart" ? "需重启" : ""}`
		+ `  ${item.secrets.length > 0 ? `secret ${item.secrets.length}` : ""}`);
}

if (wantNs !== undefined) {
	const item = settings.namespaces.find((n) => n.ns === wantNs);
	if (item === undefined) {
		console.log(`\n没有 ns「${wantNs}」`);
	} else {
		console.log(`\n=== ${wantNs} ===`);
		console.log("schema:", JSON.stringify(item.schema, null, 1).slice(0, 2000));
		console.log("value:", JSON.stringify(item.value, null, 1).slice(0, 1200));
		console.log("user:", JSON.stringify(item.user));
		console.log("secrets:", JSON.stringify(item.secrets));
	}
}

if (showProviders) {
	if (providers === undefined) await new Promise((r) => setTimeout(r, 500));
	console.log("\n=== providers ===");
	console.log(JSON.stringify(providers, null, 1));
}

// ---------------------------------------------------------------- 手工 unset

// `--unset <ns> <a.b.c>`：把一个字段退回继承。收拾探针自己留下的痕迹用得上
// （写入用例中途崩掉时，配置里会剩一个覆盖值）。
const unsetNs = valueOf("--unset");
if (unsetNs !== undefined) {
	const rawPath = args[args.indexOf("--unset") + 2];
	const path = String(rawPath ?? "").split(".").filter(Boolean);
	const seq = settingsSeq;
	const revision = settings.namespaces.find((n) => n.ns === unsetNs)?.revision;
	console.log(`\nunset ${unsetNs}.${path.join(".")} →`,
		await invoke("unset", { ns: unsetNs, path, expectedRevision: revision }));
	const after = await settingsAfter(seq);
	console.log("  user 层现在是：",
		JSON.stringify(after.namespaces.find((n) => n.ns === unsetNs)?.user));
}

// ---------------------------------------------------------------- 写入用例

if (doWrite) {
	const target = settings.namespaces.find((n) => n.ns === "agent-loop");
	if (target === undefined) {
		console.log("\n没有 agent-loop，跳过写入用例");
	} else {
		const path = ["maxParallelToolCalls"];
		const before = target.value?.maxParallelToolCalls;
		const wasOverridden = target.user !== null && "maxParallelToolCalls" in (target.user ?? {});
		console.log(`\n=== 写入用例（agent-loop.maxParallelToolCalls，当前 ${before}，`
			+ `${wasOverridden ? "已覆盖" : "继承中"}）===`);

		const next = before === 7 ? 8 : 7;
		const seqBefore = settingsSeq;
		console.log("1. set →", await invoke("set", { ns: "agent-loop", path, value: next,
			expectedRevision: target.revision }));
		const afterSet = await settingsAfter(seqBefore);
		const nowValue = afterSet.namespaces.find((n) => n.ns === "agent-loop")?.value?.maxParallelToolCalls;
		console.log(`   回读 = ${nowValue}　${nowValue === next ? "✅" : "❌ 与写入不符"}`);

		// 拿旧 revision 再写一次：必须被乐观锁挡下。
		const stale = await invoke("set", { ns: "agent-loop", path, value: next + 1,
			expectedRevision: target.revision });
		console.log(`2. 用过期 revision 再写 → ok=${stale.ok} code=${stale.code}`
			+ `　${stale.code === "SETTINGS_CONFLICT" ? "✅ 挡住了" : "❌ 没挡住"}`);

		// 收尾：恢复原状。
		if (wasOverridden) {
			const fresh = await currentRevision("agent-loop");
			await invoke("set", { ns: "agent-loop", path, value: before, expectedRevision: fresh });
			console.log(`3. 恢复原值 ${before} ✅`);
		} else {
			const fresh = await currentRevision("agent-loop");
			const seqUndo = settingsSeq;
			const undo = await invoke("unset", { ns: "agent-loop", path, expectedRevision: fresh });
			const afterUnset = await settingsAfter(seqUndo);
			const user = afterUnset.namespaces.find((n) => n.ns === "agent-loop")?.user;
			const gone = user === null || !("maxParallelToolCalls" in (user ?? {}));
			console.log(`3. unset 退回继承 → ok=${undo.ok}　${gone ? "✅ user 层已清干净" : "❌ 还留着"}`);
		}
	}
}

async function currentRevision(ns) {
	const seq = settingsSeq;
	await invoke("refresh");
	const snapshot = await settingsAfter(seq);
	return snapshot.namespaces.find((n) => n.ns === ns)?.revision;
}

ws.close();
process.exit(0);
