#!/bin/sh
# 编译并跑一次验证台。ManagedProcess.swift 是壳里那一份原文件，不抄。
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$here/.build
mkdir -p "$out"
chmod +x "$here"/fake-*.sh
swiftc -O \
  "$here/../../../clam-app/host/Sources/Native/ManagedProcess.swift" \
  "$here/main.swift" \
  -o "$out/spike"
cp "$here"/fake-*.sh "$out"/
exec "$out/spike" "$@"
