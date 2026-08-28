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

echo "==> Done: ${DEST}"
if [[ "${1:-}" == "--keep-open" ]]; then
  open "${DEST}"
fi
