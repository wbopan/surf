#!/bin/bash
# postBuild：把共享 module（目前只有 ClamSDK）摆进 app bundle，然后重新签名。
#
#   Contents/Frameworks/lib<M>.dylib        ← 壳按 @rpath 加载的那一份
#   Contents/Resources/ClamModules/         ← 运行时编译插件用的 .swiftinterface/.swiftmodule
#
# 为什么要重新签名：拷贝发生在 Xcode 自己的签名步骤之后，动了 bundle 内容就
# 破了 CodeResources 封印。ad-hoc 签名（identity "-"）代价可以忽略。
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
