#!/bin/sh
# Remove the app and its Finder service.
set -e
DEST="$HOME/Applications/OneDrive Free Up Fixer.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -d "$DEST" ] && "$LSREGISTER" -u "$DEST" || true
rm -rf "$DEST"
/System/Library/CoreServices/pbs -update
echo "removed: $DEST (remove it from Full Disk Access in System Settings too)"
