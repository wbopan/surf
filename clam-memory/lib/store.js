// clam-memory 的存储层（docs/archive/clam-memory-plan.md §2.7 / §3）。
//
// 三条硬约束：
//  1. **零依赖**——只用 node 内置模块。这个包要能装到 Linux 机器上跑（§0.0）。
//  2. **同步 API**——`ctx.systemPrompt.context()` 的 text 回调是同步的（§1.1），
//     所以 index/pinned/read 必须能同步返回。用"读缓存 + 目录签名"实现：
//     每次调用 readdir + stat 一遍（便宜），签名一致就复用上次解析好的记录。
//     **不引 watcher 依赖**。
//  3. **不新建第二个真相源**（§0.1）——磁盘上的 markdown 就是全部真相，
//     索引每次实时从 frontmatter 组装，不落任何索引文件。
//
// **2026-08-30 起本层只读**：`memory_read` / `memory_write` 两个专用工具删掉之后，
// 写入路径整个搬到了模型手里的普通 `write` / `edit` 工具上，所以这里没有 write()、
// 没有原子写、也没有按名字拼路径那套加固（没有调用者的加固只是死代码）。唯一保留的
// 写动作是 `ensureDir` —— 注入文本里那句"目录已存在"得是真的。

import fs from "node:fs";
import path from "node:path";

import { memoryDirFor, mkdirp700 } from "./paths.js";

/** §3 的常量，逐条抄自 §1.3 的实测值。 */
export const LIMITS = {
	indexLines: 200,
	indexBytes: 25000,
	scanFiles: 200,
	// 召回时显示多少字节的上限。**本层不再截断正文**（pinned 全文照发），它现在只是
	// 一个说给模型听的数字：注入文本里"超过这么多就该拆"的那句引的就是它。
	recordBytes: 4096,
	descriptionChars: 200,
	nameChars: 60,
	headLines: 30,
	headBytes: 64 * 1024,
	pinned: 8,
};

/** 保留子目录名，不进扫描（§1.3）。 */
export const RESERVED_DIRS = new Set(["team", "logs", "sessions", "proposals"]);

const FRONTMATTER_KEYS = new Set(["name", "description", "metadata"]);
const METADATA_KEYS = new Set(["node_type", "type", "originSessionId", "modified", "pinned"]);

// ── frontmatter ───────────────────────────────────────────────────────────────
// 自己写，不引 gray-matter（零依赖）。只认我们自己写得出来的那个 YAML 子集，
// 解析不了就返回 null → 调用方跳过这个文件。Claude 目录里残留的 `MEMORY.md`
// （没有 frontmatter 的旧索引）就是这样自然被滤掉的，不必特判（§2.5）。

function unquote(value) {
	const v = value.trim();
	if (v.length >= 2) {
		const a = v[0];
		const b = v[v.length - 1];
		if ((a === '"' && b === '"') || (a === "'" && b === "'")) return v.slice(1, -1);
	}
	return v;
}

/**
 * 解析 frontmatter。`text` 可以是整份文件，也可以只是文件头。
 * 返回 `{ data, bodyOffset }`；没有闭合的 `---` 或缺 name/description 时返回 null。
 */
export function parseFrontmatter(text) {
	if (typeof text !== "string") return null;
	let src = text;
	if (src.charCodeAt(0) === 0xfeff) src = src.slice(1);
	const lines = src.split("\n");
	if (lines.length === 0) return null;
	if (lines[0].replace(/\r$/, "").trim() !== "---") return null;

	const data = { name: "", description: "", metadata: {} };
	let inMetadata = false;
	let closed = false;
	let consumed = 0;

	for (let i = 1; i < lines.length; i += 1) {
		const raw = lines[i].replace(/\r$/, "");
		if (raw.trim() === "---") {
			closed = true;
			consumed = i + 1;
			break;
		}
		if (raw.trim() === "") continue;

		// 缩进行 = metadata 的子键。真实文件里是两格；宽一点，认 1 格以上。
		if (/^\s/.test(raw)) {
			if (!inMetadata) continue;
			const m = /^\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$/.exec(raw);
			if (!m) continue;
			if (METADATA_KEYS.has(m[1])) data.metadata[m[1]] = unquote(m[2]);
			continue;
		}

		const m = /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$/.exec(raw);
		if (!m) return null; // 顶层出现不认识的行 = 不是我们认的格式
		const key = m[1];
		inMetadata = key === "metadata";
		if (!FRONTMATTER_KEYS.has(key)) continue;
		if (key !== "metadata") data[key] = unquote(m[2]);
	}

	if (!closed) return null;
	if (!data.name || !data.description) return null;
	// 正文起点：闭合行之后的第一行（吃掉紧随的一个空行）。
	let bodyLine = consumed;
	if (bodyLine < lines.length && lines[bodyLine].replace(/\r$/, "").trim() === "") bodyLine += 1;
	const bodyOffset = lines.slice(0, bodyLine).reduce((n, l) => n + l.length + 1, 0);
	return { data, bodyOffset };
}

/** 只读文件头：前 30 行 / 64 KB，谁先到算谁（§3）。 */
function readHead(file, L = LIMITS) {
	let fd;
	try {
		fd = fs.openSync(file, "r");
	} catch {
		return null;
	}
	try {
		const buf = Buffer.allocUnsafe(L.headBytes);
		const n = fs.readSync(fd, buf, 0, L.headBytes, 0);
		const text = buf.toString("utf8", 0, n);
		const lines = text.split("\n");
		if (lines.length <= L.headLines) return text;
		return lines.slice(0, L.headLines).join("\n");
	} catch {
		return null;
	} finally {
		fs.closeSync(fd);
	}
}

function truthy(v) {
	return v === true || v === "true" || v === "yes" || v === "on";
}

function clamp(s, max) {
	const str = String(s == null ? "" : s).replace(/\s+/g, " ").trim();
	return str.length > max ? str.slice(0, max) : str;
}

/** 一行索引（§2.3）。 */
export function renderIndexLine(entry) {
	return "- `" + entry.name + "`: " + entry.description;
}

// ── store ─────────────────────────────────────────────────────────────────────

/**
 * @param {{ dir?: string, limits?: object }} options
 *   `dir` 是设置里的原始值（"" | "claude" | 绝对路径）。
 *   `limits` 只给测试用来把 §3 那些上限调小；生产代码别传。
 */
export function createMemoryStore({ dir = "", limits } = {}) {
	const L = limits ? { ...LIMITS, ...limits } : LIMITS;
	/** @type {Map<string, { sig: string, records: object[], files: number }>} */
	const cache = new Map();
	/** 已经确保存在过的目录（见 ensureDir）。 */
	const ensured = new Set();

	function resolveDir(cwd) {
		return memoryDirFor({ dir, cwd });
	}

	/**
	 * 扫一遍目录，拿到（缓存过的）记录表。
	 * 签名 = 每个 .md 的 名字|mtimeMs|size，任一变化即重建。
	 */
	function scan(cwd) {
		const root = resolveDir(cwd);
		let dirents;
		try {
			dirents = fs.readdirSync(root, { withFileTypes: true });
		} catch {
			return { root, records: [], files: 0 };
		}

		const stats = [];
		for (const d of dirents) {
			const base = d.name;
			if (!base.endsWith(".md")) continue;
			if (base.startsWith(".")) continue;
			if (RESERVED_DIRS.has(base.slice(0, -3))) continue;
			if (d.isDirectory()) continue;
			const full = path.join(root, base);
			let st;
			try {
				st = fs.statSync(full); // 跟随符号链接；不是普通文件就跳过
			} catch {
				continue;
			}
			if (!st.isFile()) continue;
			stats.push({ base, full, mtimeMs: st.mtimeMs, size: st.size });
		}

		const sig = stats
			.map((s) => `${s.base}|${s.mtimeMs}|${s.size}`)
			.sort()
			.join("\n");
		const hit = cache.get(root);
		if (hit && hit.sig === sig) return { root, records: hit.records, files: hit.files };

		// 文件数上限：按 mtime 倒序留最近的 200 个（§3）。
		stats.sort((a, b) => b.mtimeMs - a.mtimeMs);
		const scanned = stats.slice(0, L.scanFiles);

		const records = [];
		for (const s of scanned) {
			const head = readHead(s.full, L);
			if (head == null) continue;
			const parsed = parseFrontmatter(head);
			if (!parsed) continue; // 无合法 frontmatter = 跳过（残留的 MEMORY.md 就这样被滤掉）
			const md = parsed.data.metadata || {};
			const modified = typeof md.modified === "string" && md.modified.trim() !== "" ? md.modified.trim() : null;
			const parsedMs = modified ? Date.parse(modified) : Number.NaN;
			records.push({
				name: clamp(parsed.data.name, L.nameChars),
				description: clamp(parsed.data.description, L.descriptionChars),
				type: typeof md.type === "string" ? md.type : "",
				pinned: truthy(md.pinned),
				modified,
				// 排序键：有 modified 的排前面（按它），没有的排后面（按 mtime 兜底）。
				hasModified: Number.isFinite(parsedMs),
				sortMs: Number.isFinite(parsedMs) ? parsedMs : s.mtimeMs,
				file: s.full,
			});
		}

		records.sort((a, b) => {
			if (a.hasModified !== b.hasModified) return a.hasModified ? -1 : 1;
			if (b.sortMs !== a.sortMs) return b.sortMs - a.sortMs;
			return a.name.localeCompare(b.name);
		});

		cache.set(root, { sig, records, files: stats.length });
		return { root, records, files: stats.length };
	}

	/**
	 * 索引（§2.3 / §3）。
	 * @returns {{ entries: object[], truncated: null|{reason:string,shown:number,total:number}, text: string }}
	 */
	function index(cwd) {
		const { records, files } = scan(cwd);
		const filesCut = files > L.scanFiles;

		let kept = records;
		const linesCut = kept.length > L.indexLines;
		if (linesCut) kept = kept.slice(0, L.indexLines);

		// 字节上限：在最后一个换行处截断（§3）。
		const parts = [];
		let bytes = 0;
		let bytesCut = false;
		for (const r of kept) {
			const line = renderIndexLine(r);
			const cost = Buffer.byteLength(line, "utf8") + (parts.length === 0 ? 0 : 1);
			if (bytes + cost > L.indexBytes) {
				bytesCut = true;
				break;
			}
			bytes += cost;
			parts.push(line);
		}

		const entries = kept.slice(0, parts.length).map((r) => ({
			name: r.name,
			description: r.description,
			type: r.type,
			pinned: r.pinned,
			modified: r.modified,
		}));

		let truncated = null;
		if (bytesCut) truncated = { reason: "bytes", shown: entries.length, total: records.length };
		else if (linesCut) truncated = { reason: "lines", shown: entries.length, total: records.length };
		else if (filesCut) truncated = { reason: "files", shown: entries.length, total: files };

		return { entries, truncated, text: parts.join("\n") };
	}

	/** pinned 全文注入，最多 8 条、modified 倒序（§2.3）。 */
	function pinned(cwd) {
		const { records } = scan(cwd);
		const out = [];
		for (const r of records) {
			if (!r.pinned) continue;
			const doc = readRecordFile(r.file, r.name);
			if (!doc) continue;
			out.push({ name: r.name, content: doc.content });
			if (out.length >= L.pinned) break;
		}
		return out;
	}

	function readRecordFile(file, name) {
		let text;
		try {
			text = fs.readFileSync(file, "utf8");
		} catch {
			return undefined;
		}
		const parsed = parseFrontmatter(text);
		if (!parsed) {
			// 文件在，但不是我们认的格式（例如手写的裸 markdown）。
			// 按名字点名要的东西就照原样给回去，比 undefined 有用。
			return { name, description: "", type: "", content: text, pinnedRaw: undefined };
		}
		const md = parsed.data.metadata || {};
		return {
			name: parsed.data.name || name,
			description: parsed.data.description,
			type: typeof md.type === "string" ? md.type : "",
			content: text.slice(parsed.bodyOffset),
			pinnedRaw: md.pinned,
		};
	}

	/**
	 * 保证记忆目录存在，返回它的绝对路径。
	 *
	 * 注入文本告诉模型"The directory already exists; do not create it"——这句话必须是
	 * 真的，否则模型第一次写记忆就得先自己 mkdir，而它手上的 `write` 工具未必肯建
	 * 多级目录。**一个目录只建一次**：注入回调每 step 都跑，不该每步都进系统调用。
	 * 建不出来（只读挂载、权限）也不抛——注入照常，模型写的时候会自己撞上真错误。
	 */
	function ensureDir(cwd) {
		const root = resolveDir(cwd);
		if (ensured.has(root)) return root;
		try {
			mkdirp700(root);
		} catch {
			// 吞掉：装配路径不该因为建目录失败而赔掉一个 agent step。
		}
		ensured.add(root);
		return root;
	}

	function invalidate() {
		cache.clear();
	}

	return { resolveDir, ensureDir, index, pinned, invalidate, limits: L };
}
