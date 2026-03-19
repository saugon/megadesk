#!/bin/bash
set -euo pipefail

# Load local config if present
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && set -a && source "$SCRIPT_DIR/.env" && set +a

PROJECT="$SCRIPT_DIR/Megadesk.xcodeproj"
TMP_DMG="/tmp/megadesk-tmp.dmg"
VOLUME="Megadesk"
SIGN_ID="${MEGADESK_SIGN_ID:?Set MEGADESK_SIGN_ID in .env}"
NOTARY_PROFILE="${MEGADESK_NOTARY_PROFILE:?Set MEGADESK_NOTARY_PROFILE in .env}"
SPARKLE_BIN="$(ls -d ~/Library/Developer/Xcode/DerivedData/Megadesk-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)"

ARCHIVE="/tmp/megadesk.xcarchive"
EXPORT_DIR="/tmp/megadesk-export"
APP_PATH="$EXPORT_DIR/Megadesk.app"

echo "→ Archiving..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme Megadesk \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  | grep -E "^(error:|warning: |BUILD|ARCHIVE)"

echo "→ Exporting for Developer ID..."
rm -rf "$EXPORT_DIR"
# exportArchive exits 1 when Sparkle's XPC services lack provisioning profiles
# (expected for Developer ID distribution) — the export itself succeeds.
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  | grep -E "^(error:|warning: |EXPORT)" || true

if [ ! -d "$APP_PATH" ]; then
  echo "✗ Export failed — no app at $APP_PATH"
  exit 1
fi
codesign --verify --deep --strict "$APP_PATH" || { echo "✗ Signature verification failed"; exit 1; }

VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
DMG_OUT="$SCRIPT_DIR/Megadesk.dmg"

echo "→ Creating DMG..."
rm -f "$TMP_DMG" "$DMG_OUT"
hdiutil create -size 20m -fs HFS+ -volname "$VOLUME" "$TMP_DMG" -quiet

MOUNT="/tmp/Megadesk"
mkdir -p "$MOUNT"
hdiutil attach "$TMP_DMG" -readwrite -noverify -mountpoint "$MOUNT" -quiet
echo "  Mounted at $MOUNT"

ditto "$APP_PATH" "$MOUNT/Megadesk.app"
ln -s /Applications "$MOUNT/Applications"

# Embed custom icon inside the volume so it survives HTTP download
cp "$APP_PATH/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
sync

# Wait for Finder to discover the newly mounted volume
sleep 3

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "Megadesk"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {100, 100, 700, 520}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 160
      delay 3
      set position of item "Megadesk" of container window to {150, 210}
      set position of item "Applications" of container window to {450, 210}
      update without registering applications
      delay 5
      close
      eject
    end tell
  end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" -quiet
rm -f "$TMP_DMG"

echo "→ Setting DMG icon..."
ICNS="$APP_PATH/Contents/Resources/AppIcon.icns"
osascript -l JavaScript - <<JSEOF
ObjC.import('AppKit');
var icon = \$.NSImage.alloc.initWithContentsOfFile('$ICNS');
\$.NSWorkspace.sharedWorkspace.setIconForFileOptions(icon, '$DMG_OUT', 0);
JSEOF

echo "→ Signing DMG..."
codesign --force --sign "$SIGN_ID" "$DMG_OUT"

echo "→ Notarizing DMG..."
xcrun notarytool submit "$DMG_OUT" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "→ Stapling ticket..."
xcrun stapler staple "$DMG_OUT"

SIZE=$(du -sh "$DMG_OUT" | cut -f1)
echo "✓ Megadesk.dmg v$VERSION ($SIZE) — signed & notarized"

if [ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN/sign_update" ]; then
  echo ""
  echo "→ Sparkle EdDSA signature (paste into docs/appcast.xml):"
  "$SPARKLE_BIN/sign_update" "$DMG_OUT"
else
  echo "⚠ Sparkle sign_update not found — sign manually with sign_update $DMG_OUT"
fi
