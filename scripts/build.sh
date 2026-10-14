#!/bin/sh
# Build "OneDrive Free Up Fixer.app" into ./build (ad-hoc signed).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/OneDrive Free Up Fixer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -module-name OneDriveFreeUpFixer \
  -framework AppKit -framework FileProvider -framework UserNotifications \
  "$ROOT/Sources/main.swift" -o "$APP/Contents/MacOS/OneDriveFreeUpFixer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/fp_set_policy.py" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "built: $APP"
