#!/bin/bash
# 编译并跑一次 WebPolicy 隔离验证台。会真的把外链交给系统浏览器
# （example.com，无害）——这正是被验证的行为本身。
set -euo pipefail
cd "$(dirname "$0")"
HOST=../../../clam-app/host
OUT=$(mktemp -d)/webpolicy-harness
swiftc -o "$OUT" \
  "$HOST/Sources/Native/WebPolicy.swift" \
  "$HOST/Sources/ShellToast.swift" \
  "$HOST/Sources/ClamEndpoint.swift" \
  "$HOST/Sources/ClamPaths.swift" \
  "$HOST/Sources/Support/Log.swift" \
  "$HOST/Sources/AppInfo.swift" \
  main.swift
"$OUT"
