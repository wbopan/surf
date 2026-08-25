#!/bin/bash
# 给 dash 窗口截图，不需要它在前台、也不怕被别的窗口盖住。
# 首次运行编译 shot.swift（约 1s），之后源码没变就直接跑缓存的二进制。
#
# 权限：跑这个脚本的终端需要「屏幕录制」权限
# （系统设置 → 隐私与安全性 → 屏幕录制），否则窗口枚举会失败或只返回空标题。
#
# Usage: scripts/shot.sh [--app <name>] [--scale <n>] [out.png]
#        scripts/shot.sh --list
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="scripts/shot.swift"
BIN="build/tools/shot"

if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
  mkdir -p "$(dirname "$BIN")"
  swiftc -O "$SRC" -o "$BIN"
fi

exec "$BIN" "$@"
