#!/bin/sh
# 编译并打开标定台。产物落在 build/（gitignore）。加 --dark 走深色。
set -e
cd "$(dirname "$0")"
APP=build/GlassBlurProbe.app
# 先杀干净：app 已在跑时 `open` 只会激活旧进程，改了源码也看不到（栽过一次）
pkill -f GlassBlurProbe.app/Contents/MacOS >/dev/null 2>&1 || true
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>GlassBlurProbe</string>
  <key>CFBundleIdentifier</key><string>io.wenbo.glassblurprobe</string>
  <key>CFBundleName</key><string>Glass Blur Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
swiftc -parse-as-library -target arm64-apple-macos27.0 \
  -o "$APP/Contents/MacOS/GlassBlurProbe" Probe.swift
codesign -s - -f "$APP" >/dev/null 2>&1 || true
open "$APP" --args "$@"
