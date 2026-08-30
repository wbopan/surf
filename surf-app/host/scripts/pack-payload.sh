#!/bin/bash
# postBuild：把分发载荷打进 app bundle（分发计划 M1，docs/archive/distribution-plan.md §2.1）。
#
#   Contents/Resources/SurfNode/                 各插件的 node 半边
#   Contents/Resources/SurfPlugins/<M>/sources/  各插件的 swift/ 源码
#   Contents/Resources/SurfPayload.json          清单 + 跳过判据
#
# **只在 Release 跑**：Debug 是开发形态（node 半边从仓库 link、Swift 存盘热替换），
# 打进 bundle 的那份没有任何人读，纯粹拖慢 `./dev` 的循环。
#
# **本脚本只做门卫**，逻辑全在 pack-payload.mjs 里：要按编排表解析包名、要读写
# JSON、要按内容 hash 决定跳不跳——这三样在 bash 里都是抄一遍别处已有的算法
# （module 名尤其：唯一真相在 surf-bridge/lib/module-name.js）。
#
# **排在 embed-modules.sh 之后**。两个脚本都是 postBuildScripts，而 Xcode 自己的
# CodeSign 阶段**在全部 postBuildScripts 之后**才封外层 bundle（计划 §4.1 有构建
# 日志为证，本轮复核过），所以往 Resources/ 里塞东西不会破坏封印，也不需要重签。
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${CONFIGURATION:-}" != "Release" ]]; then
  echo "pack-payload: ${CONFIGURATION:-?} 配置不打包载荷（只有 Release 需要）"
  exit 0
fi

# Xcode 的 build phase 继承的是**启动 Xcode/xcodebuild 那个进程**的 PATH，
# 从 Finder 起的 Xcode 里可能没有 node。找不到就 fails loud——Release 产物缺了
# 载荷是个静默的坏包（装到用户机器上表现为"插件全部缺席"），不能优雅缺席。
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
  echo "error: pack-payload 需要 node，PATH 上没有找到" >&2
  echo "  Release 产物缺了 Resources/SurfNode 就是个坏包，所以这里不降级。" >&2
  exit 1
fi

exec "${NODE}" scripts/pack-payload.mjs
