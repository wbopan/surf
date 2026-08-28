#!/bin/bash
# ClamSDK：以 library evolution 编译并产出 .swiftinterface（断言 8）。
set -euo pipefail
cd "$(dirname "$0")"
OUT=out/sdk
mkdir -p "$OUT"
xcrun swiftc sdk/ClamSDK.swift \
  -module-name ClamSDK \
  -emit-library -o "$OUT/libClamSDK.dylib" \
  -emit-module -emit-module-path "$OUT/ClamSDK.swiftmodule" \
  -emit-module-interface -emit-module-interface-path "$OUT/ClamSDK.swiftinterface" \
  -enable-library-evolution -language-mode 5 \
  -Xlinker -install_name -Xlinker "@rpath/libClamSDK.dylib" \
  -target arm64-apple-macos27.0 -Onone -g
echo "SDK ok:"; ls -1 "$OUT"
