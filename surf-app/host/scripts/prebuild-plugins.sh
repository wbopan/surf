#!/bin/bash
# postBuild：把各插件的 Swift 半边预编译进 app bundle（分发计划 M3，§3.2）。
#
#   Contents/Resources/SurfPlugins/<Module>/prebuilt/<hash12>/lib<Module>_h<hash12>.dylib
#   Contents/Resources/SurfPrebuilt.json
#
# **只在 Release 跑**：Debug 是开发形态（Swift 存盘热替换，产物落用户缓存），
# 预编译一份进 bundle 没有任何人读，纯粹拖慢 `./dev` 的循环。
#
# **排在 pack-payload.sh 之后**：源码从打包好的 `Resources/SurfNode/<pkg>/swift/`
# 读，"编的就是发的"因此是结构性的。三个 postBuildScripts 的顺序是
# embed-modules（SurfSDK 进 Frameworks/SurfModules）→ pack-payload（node 半边 +
# Swift 源码）→ 本脚本（预编译），每一步都吃上一步的产物。Xcode 自己的 CodeSign
# 阶段排在全部 postBuildScripts 之后（计划 §4.1 有构建日志为证），所以这里往
# Resources/ 里塞 dylib 不破坏封印。
#
# **本脚本做两件事**：编出那个预编译工具，然后把活交给 prebuild-plugins.mjs。
# 工具的源码就是壳自己的 CompilerService.swift（外加一个 30 行的驱动），
# 所以构建机与用户机器上算 hash、拼 swiftc 参数的是同一份代码——见
# scripts/prebuild/Prebuild.swift 的顶注。
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${CONFIGURATION:-}" != "Release" ]]; then
  echo "prebuild-plugins: ${CONFIGURATION:-?} 配置不预编译插件（只有 Release 需要）"
  exit 0
fi

# ---------------------------------------------------------------- 预编译工具

OUT_DIR="build-prebuild"
TOOL="${OUT_DIR}/surf-prebuild"
STAMP="${OUT_DIR}/.sources-hash"

# 工具的输入：那四个源文件 + 编它的 swiftc。**判据里必须含真正的输入**——
# build-modules.sh 那条教训：只按源码算的话，换了工具链而源码没动会被判成
# "未变动、跳过"，而报错会出现在别处。
TOOL_SOURCES=(
  Sources/Native/CompilerService.swift
  Sources/Support/Hashing.swift
  Sources/Support/Log.swift
  scripts/prebuild/Prebuild.swift
)
WANT="$( { cat "${TOOL_SOURCES[@]}"; xcrun swiftc --version; } | shasum -a 256 | cut -d' ' -f1 )"

if [[ ! -x "${TOOL}" || "$(cat "${STAMP}" 2>/dev/null || true)" != "${WANT}" ]]; then
  mkdir -p "${OUT_DIR}"
  echo "prebuild-plugins: 编预编译工具…"
  xcrun swiftc -O -o "${TOOL}" "${TOOL_SOURCES[@]}"
  printf '%s' "${WANT}" > "${STAMP}"
fi

# ---------------------------------------------------------------- 驱动

# Xcode 的 build phase 继承的是**启动 Xcode/xcodebuild 那个进程**的 PATH，
# 从 Finder 起的 Xcode 里可能没有 node。找不到就 fails loud——Release 产物缺了
# 预编译产物是个静默的坏包（装到没有 Xcode 的用户机器上 = 插件全部缺席）。
NODE="$(command -v node || true)"
if [[ -z "${NODE}" ]]; then
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
    [[ -x "${candidate}" ]] && NODE="${candidate}" && break
  done
fi
if [[ -z "${NODE}" ]]; then
  # zsh -lc 读 .zshenv/.zprofile/.zlogin（不读 .zshrc），GUI 进程的 PATH 只能靠它补。
  NODE="$(zsh -lc 'command -v node' 2>/dev/null || true)"
fi
if [[ -z "${NODE}" ]]; then
  echo "error: prebuild-plugins 需要 node，PATH 上没有找到" >&2
  exit 1
fi

exec "${NODE}" scripts/prebuild-plugins.mjs "$(pwd)/${TOOL}"
