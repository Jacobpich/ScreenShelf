#!/bin/zsh
# Builds ScreenShelf.app and installs it to /Applications (falls back to ~/Applications).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ScreenShelf.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  ScreenShelf.swift -o "$APP/Contents/MacOS/ScreenShelf"

cp Info.plist "$APP/Contents/Info.plist"
# Sign with a stable identity so the Desktop permission and login item survive rebuilds.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null

DEST="/Applications"
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

pkill -x ScreenShelf 2>/dev/null || true
rm -rf "$DEST/ScreenShelf.app"
cp -R "$APP" "$DEST/"
echo "Installed to $DEST/ScreenShelf.app"

[[ "${1:-}" == "--no-launch" ]] || open "$DEST/ScreenShelf.app"
