#!/bin/bash
# 共享 module 编译。**目前只有 DashSDK 一个**（M10 之后 DSHKit 已退役）。
#
# 共享 module 必须**全进程只有一份**——壳链接它，运行时编出来的插件 dylib
# 也链接它（经 app bundle 内的同一个文件），类型身份才对得上。所以它不能
# 走 SwiftPM 静态链接进壳，而是编成一个 dylib 随 bundle 分发。
#
# 机制本身仍是多 module 的（`build_module` 可以再加一行），只是眼下没有第二个：
# 会话数据面搬进 dash-sidebar 的 node 半边之后，DSHKit 没有消费者了。
#
# 产物落 host/build-sdk/（不入库）：
#   lib<M>.dylib / <M>.swiftmodule / <M>.swiftinterface / <M>.swiftdoc
# postBuild 的 embed-modules.sh 再把它们摆进 app bundle。
#
# 用法：scripts/build-modules.sh [--force]
# 默认按源码内容 hash 跳过没变的 module（Xcode 每次构建都会跑一遍本脚本）。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build-sdk"
TARGET="arm64-apple-macos26.0"
FORCE="${1:-}"

mkdir -p "$OUT"

# 内容 hash（不看 mtime；换 git 分支不误判）。
sources_hash() {
  find "$@" -type f -name '*.swift' | sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1
}

build_module() { # build_module <module 名> <源码目录...>
  local module="$1"; shift
  local hash marker
  hash="$(sources_hash "$@")"
  marker="$OUT/.$module.hash"

  if [[ "$FORCE" != "--force" && -f "$OUT/lib$module.dylib" && -f "$marker" \
        && "$(cat "$marker")" == "$hash" ]]; then
    echo "  $module: 未变动，跳过（${hash:0:12}）"
    return
  fi

  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$@" -type f -name '*.swift' | sort)

  echo "  $module: 编译 ${#files[@]} 个文件…"
  # -enable-library-evolution + -emit-module-interface：插件编译时只需要
  # bundle 里的 .swiftinterface 就能重建类型身份（M2 断言 8）。
  # -language-mode 5 是 Swift 6.4 下 -emit-module-interface 的硬要求。
  xcrun swiftc "${files[@]}" \
    -module-name "$module" \
    -emit-library -o "$OUT/lib$module.dylib" \
    -emit-module -emit-module-path "$OUT/$module.swiftmodule" \
    -emit-module-interface -emit-module-interface-path "$OUT/$module.swiftinterface" \
    -enable-library-evolution -language-mode 5 \
    -I "$OUT" -L "$OUT" \
    -Xlinker -install_name -Xlinker "@rpath/lib$module.dylib" \
    -Xlinker -rpath -Xlinker "@loader_path" \
    -target "$TARGET" -Onone -g
  printf '%s' "$hash" > "$marker"
}

# ${OUT} 的花括号不是风格问题：bash 3.2（macOS 自带）在 UTF-8 locale 下会把
# 紧跟其后的全角字符吞进变量名，配上 set -u 就是 "OUT\357: unbound variable"。
echo "==> 共享 module（${OUT}）"
build_module DashSDK Sources/DashSDK
