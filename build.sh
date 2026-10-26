#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="build/截图入库.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library -O \
  -framework Cocoa -framework Carbon \
  -o "$APP/Contents/MacOS/ScreenshotIngest" \
  Sources/Hotkey.swift \
  Sources/Capture.swift \
  Sources/Overlay.swift \
  Sources/Actions.swift \
  Sources/Queue.swift \
  Sources/FailedLibrary.swift \
  Sources/App.swift
cp Info.plist "$APP/Contents/Info.plist"
SIGN_ID="Screenshot Ingest Local"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --identifier com.chenglong.screenshot-ingest "$APP"
else
  codesign --force --sign - --identifier com.chenglong.screenshot-ingest "$APP"
fi
echo "$APP"
