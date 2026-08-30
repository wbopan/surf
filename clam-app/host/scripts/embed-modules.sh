#!/bin/bash
# postBuild：把共享 module（目前只有 ClamSDK）摆进 app bundle，并给它签名。
#
#   Contents/Frameworks/lib<M>.dylib        ← 壳按 @rpath 加载的那一份
#   Contents/Resources/ClamModules/         ← 运行时编译插件用的 .swiftinterface/.swiftmodule
#
# **inside-out 是结构性的，这里不需要、也不许再签外层**（计划 §4.1，构建日志为证）：
# Xcode 的 `CodeSign` 阶段排在**全部 postBuildScripts 之后**，它封外层 bundle 时会
# 把这份 dylib 的 cdhash 一起封进去。曾经这里还有一句对整个 app 的 ad-hoc 重签，
# 那是死动作（Xcode 随后就覆盖掉），更是个活陷阱——它把身份写死成 `-`，
# 阶段一旦被重排或本脚本被单独执行，就会**静默把整个 App 降级成 ad-hoc**。M5 删了。
#
# **签名身份跟着这一轮构建走**，不写死：`EXPANDED_CODE_SIGN_IDENTITY` 是 Xcode 把
# `CODE_SIGN_IDENTITY` 解析出来的那一份——开发形态是 `-`（ad-hoc），分发形态
# （`scripts/release-dmg.sh` 用 xcodebuild 覆盖传进来）是 Developer ID。
# 写死 `-` 的后果是**外层 Developer ID、内层 ad-hoc，公证直接拒收**。
set -euo pipefail

: "${BUILT_PRODUCTS_DIR:?仅供 Xcode 构建阶段调用}"
: "${CONTENTS_FOLDER_PATH:?}"
: "${FRAMEWORKS_FOLDER_PATH:?}"
: "${WRAPPER_NAME:?}"

SRC="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}/build-sdk"
FRAMEWORKS="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
MODULES="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/ClamModules"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
SIGN=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "-" ]]; then
  # ad-hoc 拿不到 secure timestamp（那要联网找 Apple 的时间戳服务），显式关掉；
  # 反过来，真身份**必须**带 --timestamp，公证要求它。
  SIGN+=(--timestamp=none)
else
  SIGN+=(--timestamp)
fi
# 嵌套代码也要带上 Hardened Runtime 标志：公证会逐个检查 bundle 里的可执行代码。
# （写成 if 而不是 `[[ ]] && …`：后者条件为假时整句返回 1，`set -e` 会当场退出。）
if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]]; then
  SIGN+=(--options runtime)
fi

mkdir -p "$FRAMEWORKS" "$MODULES"

for module in ClamSDK; do
  cp -f "$SRC/lib$module.dylib" "$FRAMEWORKS/"
  # .swiftmodule 优先（同一 toolchain，编译更快）；.swiftinterface 是
  # toolchain 变动后的兜底，两个都给。
  for ext in swiftmodule swiftinterface swiftdoc; do
    [[ -f "$SRC/$module.$ext" ]] && cp -f "$SRC/$module.$ext" "$MODULES/"
  done
  codesign "${SIGN[@]}" "$FRAMEWORKS/lib$module.dylib"
done

echo "embed-modules: ClamSDK → ${WRAPPER_NAME}（签名身份 ${IDENTITY}）"
