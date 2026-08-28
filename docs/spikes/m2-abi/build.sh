#!/bin/bash
# 编译 SDK / 两代 alpha 插件 / 宿主，并记录各自 swiftc 耗时（断言 10 基线）。
set -euo pipefail
cd "$(dirname "$0")"
OUT=out
TARGET=arm64-apple-macos27.0

timed() { # timed <标签> <命令...>
  local label="$1"; shift
  local t0=$(python3 -c 'import time;print(time.time())')
  "$@"
  local t1=$(python3 -c 'import time;print(time.time())')
  python3 -c "print(f'  ⏱  $label: {$t1-$t0:.2f}s')"
}

# 1) SDK（library evolution + .swiftinterface）
./build-sdk.sh > /dev/null
echo "SDK 就绪"

# 2) 插件两代：同一份源码，不同 module-name + -DGEN2
build_alpha() { # build_alpha <gen> <module> [额外 flag...]
  local gen="$1" mod="$2"; shift 2
  local dir="$OUT/alpha_g$gen"
  mkdir -p "$dir"
  timed "alpha g$gen (82 行)" xcrun swiftc plugins/alpha/AlphaPlugin.swift \
    -module-name "$mod" \
    -emit-library -o "$dir/lib$mod.dylib" \
    -emit-module -emit-module-path "$dir/$mod.swiftmodule" \
    -I "$OUT/sdk" -L "$OUT/sdk" -lClamSDK \
    -Xlinker -rpath -Xlinker "@loader_path/../sdk" \
    -Xlinker -install_name -Xlinker "@rpath/lib$mod.dylib" \
    -target "$TARGET" -language-mode 5 -Onone -g "$@"
}
build_alpha 1 Alpha_g1
build_alpha 2 Alpha_g2 -DGEN2

# 3) beta：源码写 `import Alpha`，用 -module-alias 绑到具体世代（计划 §6.1）
mkdir -p "$OUT/beta"
timed "beta (35 行, import Alpha_g1)" xcrun swiftc plugins/beta/BetaPlugin.swift \
  -module-name Beta \
  -emit-library -o "$OUT/beta/libBeta.dylib" \
  -emit-module -emit-module-path "$OUT/beta/Beta.swiftmodule" \
  -I "$OUT/sdk" -L "$OUT/sdk" -lClamSDK \
  -I "$OUT/alpha_g1" -L "$OUT/alpha_g1" -lAlpha_g1 \
  -module-alias Alpha=Alpha_g1 \
  -Xlinker -rpath -Xlinker "@loader_path/../sdk" \
  -Xlinker -rpath -Xlinker "@loader_path/../alpha_g1" \
  -Xlinker -install_name -Xlinker "@rpath/libBeta.dylib" \
  -target "$TARGET" -language-mode 5 -Onone -g

# 4) 断言 8：模拟 app bundle 内分发——SDK 只给 .swiftinterface + dylib，故意不给 .swiftmodule
rm -rf "$OUT/bundle"; mkdir -p "$OUT/bundle"
cp "$OUT/sdk/ClamSDK.swiftinterface" "$OUT/sdk/libClamSDK.dylib" "$OUT/bundle/"
timed "alpha (interface-only SDK 路径)" xcrun swiftc plugins/alpha/AlphaPlugin.swift \
  -module-name Alpha_iface \
  -emit-library -o "$OUT/bundle/libAlpha_iface.dylib" \
  -I "$OUT/bundle" -L "$OUT/bundle" -lClamSDK \
  -Xlinker -rpath -Xlinker "@loader_path" \
  -target "$TARGET" -language-mode 5 -Onone -g

# 5) 宿主
timed "host (197 行)" xcrun swiftc host/main.swift \
  -o "$OUT/spike-host" \
  -I "$OUT/sdk" -L "$OUT/sdk" -lClamSDK \
  -Xlinker -rpath -Xlinker "@loader_path/sdk" \
  -target "$TARGET" -language-mode 5 -Onone -g

echo "全部就绪：$OUT/spike-host"
