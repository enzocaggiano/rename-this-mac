#!/bin/zsh
# Builds dist/Rename-this-Mac.dmg: the "Rename this Mac" app (with rename-mac.command inside)
# next to an Applications shortcut, on a background with a drag arrow.
# Run: zsh build-dmg.sh   (needs macOS with Xcode command line tools for SetFile; Finder lays out the window)

emulate zsh
setopt err_exit pipefail
cd "${0:A:h}"

APP_NAME="Rename this Mac"
VOL="Rename this Mac"
BUNDLE_ID="io.github.enzocaggiano.rename-this-mac"
VERSION=$(sed -n 's/^RM_VERSION="\(.*\)"$/\1/p' rename-mac.command)
DMG="dist/Rename-this-Mac.dmg"
BUILD=$(mktemp -d -t rename-this-mac-build)
STAGE="$BUILD/stage"
APP="$STAGE/$APP_NAME.app"
mkdir -p "$STAGE" dist
print "Building $APP_NAME $VERSION in $BUILD"

# 1. Icon: one 1024px drawing, scaled into a standard .iconset
mkdir "$BUILD/AppIcon.iconset"
osascript -l JavaScript packaging/make-art.js icon "$BUILD/icon-1024.png" 1024 >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon-1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$BUILD/icon-1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

# 2. App: an AppleScript applet that runs the bundled script
osacompile -o "$APP" packaging/app.applescript
cp rename-mac.command "$APP/Contents/Resources/rename-mac"
chmod 755 "$APP/Contents/Resources/rename-mac"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/applet.icns"
rm -f "$APP/Contents/Resources/Assets.car"
plist="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$plist" 2>/dev/null || true
pset() { /usr/libexec/PlistBuddy -c "Set :$1 $3" "$plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$plist" }
pset CFBundleIdentifier string "$BUNDLE_ID"
pset CFBundleName string "$APP_NAME"
pset CFBundleShortVersionString string "$VERSION"
pset CFBundleVersion string "$VERSION"
pset NSHumanReadableCopyright string "Copyright 2026 Enzo Caggiano. GPL-3.0-or-later."
codesign --force --deep --sign - "$APP"
codesign --verify --deep "$APP"

# 3. Disk image contents: app, Applications shortcut, hidden background (1x and 2x)
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
osascript -l JavaScript packaging/make-art.js background "$BUILD/bg.png" 1 >/dev/null
osascript -l JavaScript packaging/make-art.js background "$BUILD/bg@2x.png" 2 >/dev/null
tiffutil -cathidpicheck "$BUILD/bg.png" "$BUILD/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

[[ -d "/Volumes/$VOL" ]] && hdiutil detach "/Volumes/$VOL" -quiet
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$BUILD/rw.dmg" >/dev/null
dev=$(hdiutil attach -readwrite -noverify -noautoopen "$BUILD/rw.dmg" | awk '/Apple_HFS/ {print $1; exit}')
mnt="/Volumes/$VOL"

# Volume icon (skipped if SetFile isn't available)
if setfile=$(xcrun --find SetFile 2>/dev/null); then
  cp "$BUILD/AppIcon.icns" "$mnt/.VolumeIcon.icns"
  "$setfile" -c icnC "$mnt/.VolumeIcon.icns"
  "$setfile" -a C "$mnt"
fi

# 4. Window layout: Finder writes the .DS_Store that sets the background and icon spots
osascript <<AS
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {160, 150}
    set position of item "Applications" of container window to {480, 150}
    repeat with hiddenName in {".background", ".fseventsd", ".VolumeIcon.icns", ".Trashes"}
      try
        set position of item hiddenName of container window to {900, 900}
      end try
    end repeat
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
AS

sync
hdiutil detach "$dev" -quiet
rm -f "$DMG"
hdiutil convert "$BUILD/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
print "Built $DMG ($(du -h "$DMG" | cut -f1))"
