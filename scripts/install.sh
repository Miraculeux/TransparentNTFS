#!/usr/bin/env bash
# TransparentNTFS installer
# Builds the daemon + menu-bar app, installs the daemon as a LaunchDaemon,
# and copies the app into /Applications.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

LABEL="io.transparentntfs.daemon"
PLIST_SRC="launchd/${LABEL}.plist"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
DAEMON_DST="/usr/local/libexec/transparent-ntfsd"
APP_DST="/Applications/TransparentNTFS.app"

echo "==> Checking prerequisites"
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode command line tools are required. Run: xcode-select --install" >&2
    exit 1
fi

if ! command -v ntfs-3g >/dev/null 2>&1 \
   && [ ! -x /opt/homebrew/bin/ntfs-3g ] \
   && [ ! -x /usr/local/bin/ntfs-3g ]; then
    echo "WARNING: ntfs-3g not found in PATH or common Homebrew locations."
    echo "Install macFUSE and ntfs-3g first, e.g.:"
    echo "    brew install --cask macfuse"
    echo "    brew tap gromgit/fuse"
    echo "    brew install gromgit/fuse/ntfs-3g-mac"
    echo
fi

echo "==> Building (release)"
swift build -c release

DAEMON_BIN="$(swift build -c release --show-bin-path)/transparent-ntfsd"
APP_BIN="$(swift build -c release --show-bin-path)/TransparentNTFS"

if [ ! -x "$DAEMON_BIN" ] || [ ! -x "$APP_BIN" ]; then
    echo "Build artifacts missing." >&2
    exit 1
fi

echo "==> Installing daemon to ${DAEMON_DST} (sudo required)"
sudo mkdir -p /usr/local/libexec
sudo install -m 0755 -o root -g wheel "$DAEMON_BIN" "$DAEMON_DST"

echo "==> Installing LaunchDaemon plist"
sudo install -m 0644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST"

echo "==> Loading LaunchDaemon"
sudo launchctl unload "$PLIST_DST" 2>/dev/null || true
sudo launchctl load -w "$PLIST_DST"

echo "==> Building menu-bar app bundle"
APP_BUILD_DIR="$(mktemp -d)/TransparentNTFS.app"
mkdir -p "$APP_BUILD_DIR/Contents/MacOS"
mkdir -p "$APP_BUILD_DIR/Contents/Resources"
cp "$APP_BIN" "$APP_BUILD_DIR/Contents/MacOS/TransparentNTFS"
cat > "$APP_BUILD_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>TransparentNTFS</string>
    <key>CFBundleDisplayName</key>     <string>TransparentNTFS</string>
    <key>CFBundleIdentifier</key>      <string>io.transparentntfs.app</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>TransparentNTFS</string>
    <key>LSUIElement</key>             <true/>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "==> Installing app to ${APP_DST}"
sudo rm -rf "$APP_DST"
sudo cp -R "$APP_BUILD_DIR" "$APP_DST"

echo
echo "Done."
echo "  Daemon:     ${DAEMON_DST}"
echo "  LaunchPlist:${PLIST_DST}"
echo "  App:        ${APP_DST}"
echo "  Log:        /var/log/transparent-ntfsd.log"
echo
echo "Open the menu-bar app:  open ${APP_DST}"
