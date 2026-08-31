/*
 * 主题色色阶的换算器兼校验器。
 *
 * `client.js` 里的 ACCENT_SCALE 是**算出来写死的**（理由见那儿的注释：让浏览器
 * 用相对颜色现算会把三个饱和档一起顶到色域边界，色阶的疏密关系丢掉）。写死的
 * 代价是 dsh 哪天改了自己的 deepseek 色阶，我们这张表会悄悄 stale —— 这个脚本
 * 就是那道闸：它从**装好的 dsh theme 包**里读当前色阶，重新推一遍，再和
 * client.js 里的表逐档比对。
 *
 *   node surf-nativeify/tools/accent-scale.mjs            # 比对，不一致时 exit 1
 *   node surf-nativeify/tools/accent-scale.mjs --print    # 直接打出可粘贴的表
 *   node surf-nativeify/tools/accent-scale.mjs --theme <path/to/lib/client.js>
 *
 * 推导：拿 dsh 每一档的 OKLCh **明度原样保留**，色相换成 Surf 图标的青，彩度按
 * `品牌青C / dsh-500C` 等比缩（于是 -500 正好落回品牌青）。保明度是关键 ——
 * dsh 拿这条色阶当成对的前景/背景用，明度一动对比度就塌。
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

/** 权威源：`surf-app/host/Icons/AppIcon.icon/icon.json` 的 automatic-gradient。 */
const BRAND = "#0e8a94";
/** 锚点档：让缩放后的这一档正好落回品牌青。dsh 浅色的强调色就是它。 */
const ANCHOR = "500";

// ── sRGB ↔ OKLCh ────────────────────────────────────────────────────────────
const s2l = (v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
const l2s = (v) => (v <= 0.0031308 ? v * 12.92 : 1.055 * v ** (1 / 2.4) - 0.055);

function hex2oklch(hex) {
	const n = parseInt(hex.slice(1), 16);
	const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => s2l(v / 255));
	const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
	const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
	const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
	const A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
	const B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
	let H = (Math.atan2(B, A) * 180) / Math.PI;
	if (H < 0) H += 360;
	return { L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, C: Math.hypot(A, B), H };
}

function oklch2rgb({ L, C, H }) {
	const A = C * Math.cos((H * Math.PI) / 180), B = C * Math.sin((H * Math.PI) / 180);
	const l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3;
	const m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3;
	const s = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3;
	return [
		+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
	].map(l2s);
}

const inGamut = (rgb) => rgb.every((v) => v >= -0.0001 && v <= 1.0001);

/** 出色域时沿 OKLCh 收彩度 —— 和 CSS 自己的色域映射同向。等比缩之后基本用不上。 */
function mapToGamut(c) {
	if (inGamut(oklch2rgb(c))) return c;
	let lo = 0, hi = c.C;
	for (let i = 0; i < 40; i++) {
		const mid = (lo + hi) / 2;
		if (inGamut(oklch2rgb({ ...c, C: mid }))) lo = mid; else hi = mid;
	}
	return { ...c, C: lo };
}

const toHex = (rgb) => "#" + rgb
	.map((v) => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, "0"))
	.join("");

// ── 输入 ────────────────────────────────────────────────────────────────────
const here = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const themeArg = argv.indexOf("--theme");

/** dsh 不是本仓库的依赖，它装在 profile 里；找不到就让调用方用 --theme 指路。 */
function findTheme() {
	if (themeArg !== -1) return argv[themeArg + 1];
	const rel = "@deepseek-ai/dsh-client-ui-theme/lib/client.js";
	for (const base of [join(homedir(), ".dsh/profiles/node_modules"), join(here, "../../node_modules")]) {
		const p = join(base, rel);
		try { readFileSync(p); return p; } catch { /* 下一个候选 */ }
	}
	console.error("找不到 dsh 的 ui-theme 包。装好 profile（./dev 跑一次）或用 --theme 指路。");
	process.exit(2);
}

/** 从 dsh 的构建产物里刮出当前的 deepseek 色阶。它是压过的 CSS，一条条 `--k:#v;`。 */
function readDshScale(path) {
	const src = readFileSync(path, "utf8");
	const scale = [];
	const seen = new Set();
	for (const m of src.matchAll(/--dsw-static-deepseek-([0-9a-z-]+)\s*:\s*(#[0-9a-fA-F]{6})/g)) {
		if (seen.has(m[1])) continue;   // 浅深两档定义同值，只取第一次
		seen.add(m[1]);
		scale.push([m[1], m[2].toLowerCase()]);
	}
	if (!scale.length) { console.error(`${path} 里没找到 --dsw-static-deepseek-*`); process.exit(2); }
	return scale;
}

/** 从 client.js 里读回我们写死的那张表，用来比对。 */
function readOurScale() {
	const src = readFileSync(join(here, "..", "lib", "client.js"), "utf8");
	const block = src.match(/const ACCENT_SCALE = \[([\s\S]*?)\n\t\t\];/);
	if (!block) { console.error("client.js 里没找到 ACCENT_SCALE"); process.exit(2); }
	return [...block[1].matchAll(/\["([0-9a-z-]+)",\s*"(#[0-9a-fA-F]{6})"\]/g)]
		.map((m) => [m[1], m[2].toLowerCase()]);
}

// ── 推导 ────────────────────────────────────────────────────────────────────
const dsh = readDshScale(findTheme());
const brand = hex2oklch(BRAND);
const anchor = dsh.find(([k]) => k === ANCHOR);
if (!anchor) { console.error(`dsh 色阶里没有 -${ANCHOR} 档，锚点没了，推导方式要重想`); process.exit(2); }
const k = brand.C / hex2oklch(anchor[1]).C;

const derived = dsh.map(([step, hex]) => {
	const o = hex2oklch(hex);
	return [step, toHex(oklch2rgb(mapToGamut({ L: o.L, C: o.C * k, H: brand.H })))];
});

if (argv.includes("--print")) {
	console.log(derived.map(([s, v]) => `\t\t\t["${s}", "${v}"],`).join("\n"));
	process.exit(0);
}

// ── 比对 ────────────────────────────────────────────────────────────────────
const ours = new Map(readOurScale());
console.log(`品牌青 ${BRAND}  H=${brand.H.toFixed(2)}  彩度缩放 k=${k.toFixed(4)}（锚点 -${ANCHOR}）\n`);
console.log("档位          dsh 现值   应得      client.js");
let bad = 0;
for (const [step, want] of derived) {
	const got = ours.get(step);
	const ok = got === want;
	if (!ok) bad++;
	console.log(`${step.padEnd(12)}  ${dsh.find(([s]) => s === step)[1]}   ${want}   ${got ?? "（缺）"}  ${ok ? "" : "  ← 不一致"}`);
}
for (const step of ours.keys()) {
	if (!derived.some(([s]) => s === step)) { bad++; console.log(`${step.padEnd(12)}  —         —         ${ours.get(step)}    ← dsh 已无此档`); }
}
if (bad) {
	console.error(`\n${bad} 档对不上 —— dsh 大概改了色阶。用 --print 重新生成 ACCENT_SCALE。`);
	process.exit(1);
}
console.log("\n— 全部一致");
