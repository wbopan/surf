#!/bin/bash
# postBuild：把共享 module（目前只有 ClamSDK）摆进 app bundle，然后重新签名。
#
#   Contents/Frameworks/lib<M>.dylib        ← 壳按 @rpath 加载的那一份
#   Contents/Resources/ClamModules/         ← 运行时编译插件用的 .swiftinterface/.swiftmodule
#
# 嵌套 dylib 要自己签（inside-out：里层先签好，Xcode 再封外层）。
#
# **末尾那句对整个 app 的重签是死动作**——构建日志为证（计划 §4.1，M1 复核过）：
# Xcode 的 `CodeSign` 阶段排在**全部 postBuildScripts 之后**，我们签完它还会再签
# 一遍。留着它不只是浪费：它把身份写死成 `-`，阶段一旦被重排或本脚本被单独执行，
# 就会**静默把整个 App 降级成 ad-hoc**。M5（签名公证）连同 `--timestamp=none`
# 一起删。
set -euo pipefail

: "${BUILT_PRODUCTS_DIR:?仅供 Xcode 构建阶段调用}"
: "${CONTENTS_FOLDER_PATH:?}"
: "${FRAMEWORKS_FOLDER_PATH:?}"
: "${WRAPPER_NAME:?}"

SRC="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}/build-sdk"
APP="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME"
FRAMEWORKS="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
MODULES="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/ClamModules"

mkdir -p "$FRAMEWORKS" "$MODULES"

for module in ClamSDK; do
  cp -f "$SRC/lib$module.dylib" "$FRAMEWORKS/"
  # .swiftmodule 优先（同一 toolchain，编译更快）；.swiftinterface 是
  # toolchain 变动后的兜底，两个都给。
  for ext in swiftmodule swiftinterface swiftdoc; do
    [[ -f "$SRC/$module.$ext" ]] && cp -f "$SRC/$module.$ext" "$MODULES/"
  done
  codesign --force --sign - --timestamp=none "$FRAMEWORKS/lib$module.dylib"
done

# 重新封印整个 bundle。
codesign --force --sign - --timestamp=none "$APP"
echo "embed-modules: ClamSDK → $WRAPPER_NAME"
