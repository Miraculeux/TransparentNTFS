#!/usr/bin/env bash
# TransparentNTFS uninstaller
set -euo pipefail

LABEL="io.transparentntfs.daemon"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
DAEMON_DST="/usr/local/libexec/transparent-ntfsd"
APP_DST="/Applications/TransparentNTFS.app"

echo "==> Unloading LaunchDaemon"
sudo launchctl unload -w "$PLIST_DST" 2>/dev/null || true

echo "==> Removing files"
sudo rm -f "$PLIST_DST"
sudo rm -f "$DAEMON_DST"
sudo rm -rf "$APP_DST"

echo "Done. (Log file at /var/log/transparent-ntfsd.log was left in place.)"
