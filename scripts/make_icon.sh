#!/bin/sh
# Regenerate Resources/AppIcon.icns from scripts/make_icon.swift.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
swift "$ROOT/scripts/make_icon.swift" "$WORK/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$WORK/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
rm -rf "$WORK"
echo "wrote Resources/AppIcon.icns"
