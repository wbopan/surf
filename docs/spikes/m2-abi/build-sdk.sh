#!/bin/bash
# DashSDK：以 library evolution 编译并产出 .swiftinterface（断言 8）。
set -euo pipefail
cd "$(dirname "$0")"
OUT=out/sdk
mkdir -p "$OUT"
xcrun swiftc sdk/DashSDK.swift \
  -module-name DashSDK \
  -emit-library -o "$OUT/libDashSDK.dylib" \
  -emit-module -emit-module-path "$OUT/DashSDK.swiftmodule" \
  -emit-module-interface -emit-module-interface-path "$OUT/DashSDK.swiftinterface" \
  -enable-library-evolution -language-mode 5 \
  -Xlinker -install_name -Xlinker "@rpath/libDashSDK.dylib" \
  -target arm64-apple-macos27.0 -Onone -g
echo "SDK ok:"; ls -1 "$OUT"
