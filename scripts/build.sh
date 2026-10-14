#!/bin/sh
# Build "OneDrive Free Up Fixer.app" into ./build (ad-hoc signed).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/OneDrive Free Up Fixer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Apple Silicon only, macOS 13 or later.
swiftc -O -module-name OneDriveFreeUpFixer -target arm64-apple-macos13.0 \
  -framework AppKit -framework FileProvider -framework UserNotifications -lsqlite3 \
  "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/OneDriveFreeUpFixer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# Release builds pass VERSION (e.g. from a git tag "v1.2.0" -> 1.2.0).
if [ -n "$VERSION" ]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
echo "built: $APP"
