#!/bin/sh
# Build, install to ~/Applications and register the "Repair & Free Up Unpinned Files" Finder service.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="OneDrive Free Up Fixer.app"
DEST="$HOME/Applications/$NAME"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$ROOT/scripts/build.sh"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$ROOT/build/$NAME" "$DEST"
"$LSREGISTER" -f "$DEST"
/System/Library/CoreServices/pbs -update
# Refresh cached icons (Finder, Notification Center) in case an older build was registered.
touch "$DEST"
killall usernoted NotificationCenter 2>/dev/null || true
echo "installed: $DEST"
echo
echo "Next: give the app Full Disk Access. In System Settings > Privacy & Security > Full Disk Access,"
echo "drag \"OneDrive Free Up Fixer\" in from the Finder window that just opened (~/Applications)."
echo "Rebuilding re-signs the app, so the permission has to be granted again after each install."
open -R "$DEST"
