#!/bin/sh
# 编译并打开对照台。产物落在 build/ 下（gitignore）。
set -e
cd "$(dirname "$0")"
APP=build/GlassProbe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>GlassProbe</string>
  <key>CFBundleIdentifier</key><string>io.wenbo.glassprobe</string>
  <key>CFBundleName</key><string>Glass Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
swiftc -parse-as-library -target arm64-apple-macos27.0 \
  -o "$APP/Contents/MacOS/GlassProbe" Probe.swift
codesign -s - -f "$APP" >/dev/null 2>&1 || true
open "$APP"
