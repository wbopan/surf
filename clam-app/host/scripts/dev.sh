#!/bin/bash
# Debug build: generate project, build Debug config, restart the Dev app.
# Never touches the installed Release app (Surfclam) — Dev/Release are
# separate apps meant to run side by side. Pass --quit-release only if you
# explicitly want the Release app quit first.
# Usage: scripts/dev.sh [--quit-release]
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Surfclam Dev"               # Debug product name (project.yml configs.Debug)
RELEASE_NAME="Surfclam"               # installed Release app name
TARGET_NAME="surfclam"
CONFIGURATION="Debug"
DERIVED_DATA="build"
PRODUCT_PATH="build/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

# 默认保留 Release App（两者可并存）；--quit-release 才退出它。
if [[ "${1:-}" == "--quit-release" ]]; then
  osascript -e "tell application \"${RELEASE_NAME}\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    pgrep -f "/Applications/${RELEASE_NAME}.app/Contents/MacOS/" >/dev/null || break
    sleep 0.5
  done
  if pgrep -f "/Applications/${RELEASE_NAME}.app/Contents/MacOS/" >/dev/null; then
    echo "warning: ${RELEASE_NAME} still running; continuing anyway" >&2
  fi
fi

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
  | tail -n 5

if [[ ! -d "${PRODUCT_PATH}" ]]; then
  echo "error: build product not found at ${PRODUCT_PATH}" >&2
  exit 1
fi

# 退出正在运行的 Dev 实例（Swift 改动必须退出重启，⌘R 重载页面不够）。
osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  pgrep -f "${PRODUCT_PATH}/Contents/MacOS/" >/dev/null || break
  sleep 0.5
done
if pgrep -f "${PRODUCT_PATH}/Contents/MacOS/" >/dev/null; then
  echo "error: ${APP_NAME} still running after quit; close it and re-run" >&2
  exit 1
fi

echo "==> Launching ${APP_NAME}..."
open "${PRODUCT_PATH}"
