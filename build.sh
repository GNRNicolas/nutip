#!/bin/bash
# Builds Nutip.app, optionally installing it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Nutip"
ID="fr.nicolasgarnier.nutip"
VERSION="1.2"
BUILD="2"
APP="build/$NAME.app"

# Swift's shared module cache is what makes a rebuild take seconds. Leave it
# where Swift puts it; NUTIP_MODULE_CACHE overrides it for sandboxed builds.
compile() {
  if [ -n "${NUTIP_MODULE_CACHE:-}" ]; then
    mkdir -p "$NUTIP_MODULE_CACHE"
    swiftc "$@" -module-cache-path "$NUTIP_MODULE_CACHE"
  else
    swiftc "$@"
  fi
}

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- Icon: Resources/icon.png if you made one, an emoji otherwise ----------
if [ ! -f "Resources/$NAME.icns" ]; then
  mkdir -p Resources "build/$NAME.iconset"
  if [ -f Resources/icon.png ]; then
    for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
                "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
      pixels="${pair% *}"
      label="${pair#* }"
      sips -z "$pixels" "$pixels" Resources/icon.png --out "build/$NAME.iconset/icon_$label.png" >/dev/null
    done
  else
    compile -O -o build/makeicon Tools/makeicon.swift
    ./build/makeicon "build/$NAME.iconset"
  fi
  iconutil -c icns -o "Resources/$NAME.icns" "build/$NAME.iconset"
fi
cp "Resources/$NAME.icns" "$APP/Contents/Resources/"
# Readability (Mozilla, Apache 2.0) and our DOM→Markdown walker, run inside
# the hidden web view that reads a page.
cp Resources/Readability.js Resources/tomarkdown.js "$APP/Contents/Resources/"

# --- Binary -----------------------------------------------------------------
compile -O -target arm64-apple-macos13.0 -lsqlite3 \
  -o "$APP/Contents/MacOS/$NAME" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleIconFile</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Agent app: no Dock icon, no application menu bar. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature with a stable identifier. Nutip asks for no TCC permission
# (it only reads the clipboard), so a rebuild never costs the user anything.
codesign --force --sign "${NUTIP_SIGN_IDENTITY:--}" --identifier "$ID" "$APP"

# --- Install ----------------------------------------------------------------
if [ "${1:-}" = "--install" ]; then
  if pkill -f "$NAME.app/Contents/MacOS/$NAME" 2>/dev/null; then
    sleep 2
  fi
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" "/Applications/"
  rm -rf "$APP"
  open "/Applications/$NAME.app"
  echo "→ installed in /Applications and started"
  echo "  Look for the tray icon in the menu bar. The default hotkey is ⌥⌘S."
  # The same binary is the CLI. Link it where the shell will find it.
  for dir in /opt/homebrew/bin /usr/local/bin; do
    if [ -d "$dir" ] && [ -w "$dir" ]; then
      ln -sf "/Applications/$NAME.app/Contents/MacOS/$NAME" "$dir/nutip"
      echo "  CLI: $dir/nutip  (try: nutip recent)"
      break
    fi
  done
else
  echo "→ $(pwd)/$APP"
fi
