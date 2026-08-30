#!/bin/bash
# SurfSDK：以 library evolution 编译并产出 .swiftinterface（断言 8）。
set -euo pipefail
cd "$(dirname "$0")"
OUT=out/sdk
mkdir -p "$OUT"
xcrun swiftc sdk/SurfSDK.swift \
  -module-name SurfSDK \
  -emit-library -o "$OUT/libSurfSDK.dylib" \
  -emit-module -emit-module-path "$OUT/SurfSDK.swiftmodule" \
  -emit-module-interface -emit-module-interface-path "$OUT/SurfSDK.swiftinterface" \
  -enable-library-evolution -language-mode 5 \
  -Xlinker -install_name -Xlinker "@rpath/libSurfSDK.dylib" \
  -target arm64-apple-macos27.0 -Onone -g
echo "SDK ok:"; ls -1 "$OUT"
