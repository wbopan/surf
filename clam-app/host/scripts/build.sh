#!/bin/bash
# Release build: generate project, build Release config, install to /Applications.
# Usage: scripts/build.sh [--keep-open]
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Surfclam"                  # product/bundle display name (PRODUCT_NAME)
TARGET_NAME="surfclam"               # target / scheme / .xcodeproj name
INSTALL_DIR="/Applications"
CONFIGURATION="Release"
DERIVED_DATA="build"
PRODUCT_PATH="build/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

# 源码 hash 与 marker 路径都问 node 要（算法的唯一真相在 lib/source-hash.js）。
# **在动任何东西之前问**：时间戳文件是排除项、xcodegen 只写 .xcodeproj，两者都不进
# hash，但先取一次总归更接近"这一份源码"。node 不在（或模块缺席）就整个跳过写 marker
# ——那时常驻 dsh 会白编一次，不影响正确性。
SOURCE_HASH="$(node ../lib/source-hash.js hash 2>/dev/null || true)"
HASH_MARKER="$(node ../lib/source-hash.js marker "${CONFIGURATION}" 2>/dev/null || true)"

# 时间戳文件不入库：generate 扫描目录前先创建，否则新克隆的首次构建产物缺该资源。
scripts/write-build-timestamp.sh

# xcodegen 二进制不入库（.gitignore `/clam-app/host/tools/`），新克隆 / 新 worktree
# 里没有它。不拦这一下，报错就只有一句 "No such file or directory"。
if [[ ! -x ./tools/xcodegen ]]; then
  echo "error: 缺 $(pwd)/tools/xcodegen（该二进制不入库）" >&2
  echo "  补法：在仓库根跑一次 ./dev（会自动从同仓库的其它 worktree 或 PATH 拷一份），" >&2
  echo "  或 brew install xcodegen 后 cp \"\$(which xcodegen)\" ./tools/xcodegen" >&2
  exit 1
fi

echo "==> Generating Xcode project..."
./tools/xcodegen generate

echo "==> Building ${CONFIGURATION}..."
xcodebuild -project "${TARGET_NAME}.xcodeproj" -scheme "${TARGET_NAME}" \
  -configuration "${CONFIGURATION}" -derivedDataPath "${DERIVED_DATA}" build \
  | tail -n 20

if [[ ! -d "${PRODUCT_PATH}" ]]; then
  echo "error: build product not found at ${PRODUCT_PATH}" >&2
  exit 1
fi

echo "==> Installing to ${INSTALL_DIR}..."
# Quit running instance first, else copy may hit locked files.
# The app answers quit with .terminateLater while it reaps the harness process
# group (up to ~6s), so poll for the process to actually go away instead of
# guessing with a fixed sleep -- deleting a bundle still in use breaks the
# running instance.
osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
# 只等 /Applications 里的 Release 实例退出；Debug 版（Surfclam Dev.app，
# bundle id io.wenbo.surfclam.dev）名字不同，不会被误杀，可继续运行。
RUNNING="${INSTALL_DIR}/${APP_NAME}.app/Contents/MacOS/"
for _ in $(seq 1 30); do
  pgrep -f "${RUNNING}" >/dev/null || break
  sleep 0.5
done
if pgrep -f "${RUNNING}" >/dev/null; then
  echo "error: ${APP_NAME} still running after quit; close it and re-run" >&2
  exit 1
fi

# 清掉历次改名前的旧安装（DSHarness → DeepSeek Harness → dash → Surfclam）
rm -rf "${INSTALL_DIR}/DSHarness.app" "${INSTALL_DIR}/DeepSeek Harness.app" "${INSTALL_DIR}/dash.app"

DEST="${INSTALL_DIR}/${APP_NAME}.app"
rm -rf "${DEST}"
ditto "${PRODUCT_PATH}" "${DEST}"

# **换了图标却还是旧图标**，就是这一步没做。`ditto` 连同源目录的 mtime 一起拷，
# 而 build/ 里那个 bundle 目录的 mtime 停在它第一次被创建的那一刻（后续增量构建
# 只改内部文件），于是 /Applications 里这份的 mtime 也是旧的——LaunchServices 按
# **bundle 目录的 mtime** 判断"要不要重读图标"，看到没变就继续画缓存里的旧图。
# 症状彻底静默：bundle 内容、Info.plist、Assets.car 全是新的，`NSWorkspace` 查出来
# 也是新的，只有 Dock / Finder 顽固地画旧的（2026-08-30 实测踩过，旧鲸鱼图标）。
touch "${DEST}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[[ -x "${LSREGISTER}" ]] && "${LSREGISTER}" -f "${DEST}" >/dev/null 2>&1 || true

# 记一笔"这个 hash 已经构建过了"。**这份账是 clam-app 的**（node 半边按它决定要不要
# 重建），但手跑本脚本 / `./release` 也是一次真实的构建——不记的话，常驻 dsh 一起来
# 就发现 marker 与源码对不上，把刚装好的这份原样再编一遍，还会朝用户的窗口挂一条
# "壳有新版本"。见 docs/release-install-plan.md §2.5。
if [[ -n "${SOURCE_HASH}" && -n "${HASH_MARKER}" ]]; then
  mkdir -p "$(dirname "${HASH_MARKER}")"
  printf '%s' "${SOURCE_HASH}" > "${HASH_MARKER}"
  echo "==> Source hash marker: ${HASH_MARKER}"
fi

echo "==> Done: ${DEST}"
if [[ "${1:-}" == "--keep-open" ]]; then
  open "${DEST}"
fi
