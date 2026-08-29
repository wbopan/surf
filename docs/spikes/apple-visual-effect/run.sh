#!/bin/sh
# 编译并打开 spike。产物落在 build/ 下（gitignore）。
#
#   ./run.sh                                  # 开私有开关（默认）
#   CLAM_SPIKE_NO_SYSTEM_APPEARANCE=1 ./run.sh  # 对照组：不开，看 CSS.supports 翻回 false
#
# 右键菜单转储会落在 build/menu-dump.txt（在窗口里右键一次就有）。
set -e
cd "$(dirname "$0")"
APP=build/VisualEffectSpike.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>VisualEffectSpike</string>
  <key>CFBundleIdentifier</key><string>io.wenbo.visualeffectspike</string>
  <key>CFBundleName</key><string>VisualEffect Spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
cp index.html "$APP/Contents/Resources/index.html"
swiftc -parse-as-library -target arm64-apple-macos27.0 \
  -o "$APP/Contents/MacOS/VisualEffectSpike" Probe.swift
codesign -s - -f "$APP" >/dev/null 2>&1 || true
open -n "$APP"
