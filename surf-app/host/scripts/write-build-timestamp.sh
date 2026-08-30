#!/bin/bash
# Prebuild phase: stamp build time into app resources so the Dev UI can show
# exactly which build is running (Debug builds only matter, but stamping
# unconditionally is harmless).
set -euo pipefail
cd "$(dirname "$0")/.."
# Resources/ 只装这一个文件，而它是 gitignored 的——git 不跟踪空目录，所以新克隆
# 和新 worktree 里根本没有这个目录。不 mkdir 的话第一次构建就死在重定向上。
mkdir -p Sources/Resources
date "+%Y-%m-%d %H:%M:%S" > Sources/Resources/BuildTimestamp.txt
