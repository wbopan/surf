#!/bin/bash
# 分发流水线：Developer ID 签名 + Hardened Runtime 构建 → dmg → 签 dmg →（公证）。
# 权威计划 docs/archive/distribution-plan.md §4 与 §5。
#
# 用法：
#   scripts/release-dmg.sh [--identity <名字>] [--skip-notarize]
#                          [--notarize-profile <notarytool keychain profile>]
#                          [--clean] [--out <目录>]
#
# **它不碰 /Applications，也不碰 build/。** 产物全落 `build-dist/`：
#   build-dist/Build/Products/Release/Surf.app     签好的 App
#   build-dist/Surf-<版本>.dmg                     磁盘映像
# 用**独立的 derivedDataPath**有两个理由：① 开发形态那份 Release 产物
# （`./release` 装机用的、ad-hoc 签名的那个）不被这一轮的 Developer ID 产物覆盖；
# ② 顺带保证 `CodeSign` 阶段必然真的跑一遍——增量构建下它可能被判定为不必重跑
# （计划 §4.1a）。代价是每次全量编译，发布路径上无所谓。
#
# **签名的知识只有一份**：entitlements 在 project.yml 的 `entitlements.properties`
# 里（xcodegen 每次重写那个 plist，手改静默丢失，§4.3）；嵌套代码由
# `embed-modules.sh` 与 `prebuild/Prebuild.swift` 在构建过程中就地签好，
# 用的是同一个 `EXPANDED_CODE_SIGN_IDENTITY`。所以本脚本**不做任何事后重签**——
# 那会破坏 Xcode 已封好的印，还会把身份/entitlements 复制出第二份。
# 本脚本只负责：把身份和三个开关递给 xcodebuild、验、打包、签 dmg。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Surf"
TARGET_NAME="surf"
CONFIGURATION="Release"
DERIVED_DATA="build-dist"
PRODUCT_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

IDENTITY="${SURF_SIGN_IDENTITY:-}"
NOTARIZE_PROFILE=""
SKIP_NOTARIZE=0
CLEAN=0
OUT_DIR="${DERIVED_DATA}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)          IDENTITY="$2"; shift 2 ;;
    --notarize-profile)  NOTARIZE_PROFILE="$2"; shift 2 ;;
    --skip-notarize)     SKIP_NOTARIZE=1; shift ;;
    --clean)             CLEAN=1; shift ;;
    --out)               OUT_DIR="$2"; shift 2 ;;
    -h|--help)           sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "error: 不认识的参数 $1（--help 看用法）" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- 签名身份

if [[ -z "${IDENTITY}" ]]; then
  # 钥匙串里那条 Developer ID Application。多于一条就让人自己点名——猜错了要到
  # 公证那一步才发现。
  # /bin/bash 在 macOS 上是 3.2，没有 mapfile。
  FOUND=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && FOUND+=("${line}")
  done < <(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')
  if [[ ${#FOUND[@]} -eq 0 ]]; then
    echo "error: 钥匙串里没有 Developer ID Application 证书" >&2
    echo "  它来自 Apple Developer Program（99 USD/年）；申请与导入见计划 §4.4。" >&2
    exit 1
  fi
  if [[ ${#FOUND[@]} -gt 1 ]]; then
    echo "error: 有多条 Developer ID Application，用 --identity 点名：" >&2
    printf '  %s\n' "${FOUND[@]}" >&2
    exit 1
  fi
  IDENTITY="${FOUND[0]}"
fi
echo "==> 签名身份：${IDENTITY}"

# ---------------------------------------------------------------- 构建

if [[ ! -x ./tools/xcodegen ]]; then
  echo "error: 缺 $(pwd)/tools/xcodegen（该二进制不入库）" >&2
  echo "  补法：在仓库根跑一次 ./dev，或 brew install xcodegen 后拷进来。" >&2
  exit 1
fi

if [[ ${CLEAN} -eq 1 ]]; then rm -rf "${DERIVED_DATA}"; fi

# 时间戳文件不入库：generate 扫描目录前先创建。
scripts/write-build-timestamp.sh

echo "==> xcodegen generate…"
./tools/xcodegen generate

echo "==> 构建 ${CONFIGURATION}（Developer ID + Hardened Runtime）…"
# 四个覆盖，每个都缺一不可（计划 §4.2 / §4.3）：
#   CODE_SIGN_IDENTITY               ← 真身份；embed-modules.sh 与预编译工具读的
#                                      EXPANDED_CODE_SIGN_IDENTITY 由它推出
#   ENABLE_HARDENED_RUNTIME=YES      ← 公证的前提
#   CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ← 摘掉 get-task-allow（公证直接拒它）
#   OTHER_CODE_SIGN_FLAGS=--timestamp     ← 外层也要 secure timestamp
# 命令行传的 build setting 优先级高于 project.yml 里的一切，所以**开发形态
# 一个字都不受影响**：`./dev`、`./release`、build.sh 走的还是 ad-hoc 那条路。
xcodebuild -project "${TARGET_NAME}.xcodeproj" -scheme "${TARGET_NAME}" \
  -configuration "${CONFIGURATION}" -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGN_IDENTITY="${IDENTITY}" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build | tail -n 20

[[ -d "${PRODUCT_PATH}" ]] || { echo "error: 没有产物 ${PRODUCT_PATH}" >&2; exit 1; }

# ---------------------------------------------------------------- 验

echo "==> 验签名…"
codesign -v --deep --strict --verbose=2 "${PRODUCT_PATH}"

ENTS="$(codesign -d --entitlements - "${PRODUCT_PATH}" 2>/dev/null || true)"
if ! grep -q "com.apple.security.cs.disable-library-validation" <<<"${ENTS}"; then
  echo "error: entitlements 里没有 disable-library-validation" >&2
  echo "  少了它，Hardened Runtime 下现场编译出来的插件（ad-hoc 签名）一个都" >&2
  echo "  dlopen 不了——整个热插件机制在分发形态下是死的。见计划 §4.3。" >&2
  exit 1
fi
if grep -q "get-task-allow" <<<"${ENTS}"; then
  echo "error: entitlements 里还有 get-task-allow，公证会直接拒收" >&2
  echo "  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO 没生效？见计划 §4.2。" >&2
  exit 1
fi
codesign -d --verbose=4 "${PRODUCT_PATH}" 2>&1 | grep -E "^(Authority|TeamIdentifier|Timestamp|Signature|Runtime|CodeDirectory)" || true

# 嵌套代码的身份必须和外层一致——外层 Developer ID、内层 ad-hoc 的包公证直接拒。
echo "==> 验嵌套代码的签名身份…"
NESTED_BAD=0
while IFS= read -r -d '' dylib; do
  # 两处都会让这个检查**全线误报**（签名明明是好的、脚本却红成一片）：
  # ① **必须 --verbose=4**——`codesign -dv`（verbose 2）根本不打印 Authority 行；
  # ② **不能写成 `codesign … | grep -q`**——`grep -q` 命中即退出，上游 codesign
  #    吃到 SIGPIPE（141），而本脚本开着 `pipefail`，整条管道于是判失败。
  #    先取到字符串再 grep。
  DESC="$(codesign -d --verbose=4 "${dylib}" 2>&1 || true)"
  if ! grep -q "^Authority=Developer ID Application" <<<"${DESC}"; then
    echo "  ✗ ${dylib#${PRODUCT_PATH}/}" >&2
    NESTED_BAD=1
  fi
done < <(find "${PRODUCT_PATH}/Contents" -name '*.dylib' -print0)
if [[ ${NESTED_BAD} -eq 1 ]]; then
  echo "error: 上面这些嵌套 dylib 不是 Developer ID 签的（见计划 §4.2）" >&2
  exit 1
fi
echo "  嵌套 dylib 全部 Developer ID：$(find "${PRODUCT_PATH}/Contents" -name '*.dylib' | wc -l | tr -d ' ') 个"

# ---------------------------------------------------------------- 公证：app 那一半

# **公证要做两次、staple 两处，而且顺序不能换**（计划 §4.4）：
#   ① 先把 **app** 交公证 → `stapler staple` 那个 .app
#   ② 然后拿**已经 staple 过的 app** 打 dmg → 签 dmg → 交公证 → staple dmg
# 反过来（先打 dmg 再回头 staple app）是做不到的：stapler 按 cdhash 取票，
# 改了 app 就等于换了一个 dmg，之前那张票对不上号。
#
# 提交用 zip（zip **不能 staple**，只是个运输容器——这正是别的项目那套
# "ditto -c -k → 公证 → staple → 再 ditto -c -k" 舞步的由来，计划 §4.4）。
notarize() {
  local what="$1"
  echo "==> 公证 ${what}（--wait，可能要几分钟）…"
  # --timeout 给宽：2026 年有若干报告公证卡在 In Progress 超过一小时（计划 §4.4）。
  xcrun notarytool submit "${what}" --keychain-profile "${NOTARIZE_PROFILE}" \
    --wait --timeout 2h
}

if [[ -n "${NOTARIZE_PROFILE}" ]]; then
  ZIP="${DERIVED_DATA}/${APP_NAME}-notarize.zip"
  rm -f "${ZIP}"
  ditto -c -k --keepParent "${PRODUCT_PATH}" "${ZIP}"
  notarize "${ZIP}"
  rm -f "${ZIP}"
  echo "==> staple app…"
  xcrun stapler staple "${PRODUCT_PATH}"
  xcrun stapler validate "${PRODUCT_PATH}"
fi

# ---------------------------------------------------------------- dmg

command -v dmgbuild >/dev/null || {
  echo "error: 没有 dmgbuild" >&2
  echo "  补法：pip install dmgbuild（或 uv tool install dmgbuild）。选型理由见计划 §5.1。" >&2
  exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${PRODUCT_PATH}/Contents/Info.plist")"
mkdir -p "${OUT_DIR}"
DMG="${OUT_DIR}/${APP_NAME}-${VERSION}.dmg"
rm -f "${DMG}"

echo "==> 打 dmg（APFS / ULFO）…"
dmgbuild -s scripts/dmg-settings.py -D "app=$(pwd)/${PRODUCT_PATH}" \
  "${APP_NAME} ${VERSION}" "${DMG}"

echo "==> 签 dmg…"
codesign --force --timestamp --sign "${IDENTITY}" "${DMG}"
codesign -v --verbose=2 "${DMG}"

echo "==> dmg：${DMG}"
# hdiutil 在 macOS 27 上打弃用警告（走 stderr，不影响解析；计划 §5.3）。
hdiutil imageinfo "${DMG}" 2>/dev/null \
  | grep -E "^(Format|Format Description|Class Name)|partition-name|Apple_APFS" || true

# ---------------------------------------------------------------- 公证：dmg 那一半

# **没有公证凭据就到此为止，而且说清楚缺什么。** 未公证的 dmg 在别人的机器上
# 会被 Gatekeeper 拦下（"无法打开，因为 Apple 无法检查其是否包含恶意软件"），
# 只在本机能用——所以默认**非零退出**，不让"忘了公证"混成一次成功的发布。
if [[ -z "${NOTARIZE_PROFILE}" ]]; then
  echo
  echo "─────────────────────────────────────────────────────────────"
  echo "未公证（notarization），dmg 只能在本机用。"
  echo
  echo "缺的是 notarytool 的凭据，两种任选其一（计划 §4.4）："
  echo "  · App Store Connect API key（.p8 + Key ID + Issuer ID）"
  echo "    xcrun notarytool store-credentials <profile 名> \\"
  echo "      --key <AuthKey_XXX.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>"
  echo "    注意：--issuer **只给 Team API Key 用**，Individual key 传了反而报错。"
  echo "  · Apple ID + app-specific password + Team ID"
  echo "    xcrun notarytool store-credentials <profile 名> \\"
  echo "      --apple-id <邮箱> --team-id HJDT6NYKJC --password <专用密码>"
  echo
  echo "存好之后重跑：scripts/release-dmg.sh --notarize-profile <profile 名>"
  echo "─────────────────────────────────────────────────────────────"
  if [[ ${SKIP_NOTARIZE} -eq 1 ]]; then
    echo "（--skip-notarize：按要求跳过，退出码 0）"
    exit 0
  fi
  exit 3
fi

notarize "${DMG}"
echo "==> staple dmg…"
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"
spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG}"
echo "==> 完成：${DMG}"
