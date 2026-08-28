#!/bin/bash
# 给 Surfclam 窗口截图，不需要它在前台、也不怕被别的窗口盖住。
# 首次运行编译 shot.swift（约 1s），之后源码没变就直接跑缓存的二进制。
#
# 住在仓库根 tools/ 而不是 clam-app/host/scripts/：它截的是任意窗口，
# 调用方散在 docs/spikes 与各插件里，clam-app 自己一次都不用它。
# 待在 host/scripts 下还有两笔学费——那目录同时是壳的 HASHED_ROOTS
# 与 npm files 白名单，改一行截图代码要壳全量重建，还会发给用户。
#
# 权限：跑这个脚本的终端需要「屏幕录制」权限
# （系统设置 → 隐私与安全性 → 屏幕录制），否则窗口枚举会失败或只返回空标题。
#
# Usage: tools/shot.sh [--app <name>] [--scale <n>] [out.png]   # 默认落 .scratch/shot.png
#        tools/shot.sh --list
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="tools/shot.swift"
BIN="tools/.cache/shot"

if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
  mkdir -p "$(dirname "$BIN")"
  swiftc -O "$SRC" -o "$BIN"
fi

exec "$BIN" "$@"
