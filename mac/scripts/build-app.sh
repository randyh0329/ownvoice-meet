#!/bin/bash
# Builds OwnVoice Meet.app (Apple Silicon, macOS 26+) and a .dmg into mac/build/.
# Signs with $SIGN_IDENTITY (a Developer ID) when set, ad hoc otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/check-strings.py >/dev/null || { python3 scripts/check-strings.py; exit 1; }

swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)/OwnVoiceMeet"

app="build/OwnVoice Meet.app"
rm -rf build
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/OwnVoiceMeet"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp -R Resources/*.lproj "$app/Contents/Resources/"
plutil -lint "$app/Contents/Info.plist" "$app"/Contents/Resources/*.lproj/*.strings

codesign --force --options runtime --entitlements Resources/OwnVoiceMeet.entitlements \
  --sign "${SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
staging=build/dmg
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "OwnVoice Meet" -srcfolder "$staging" -ov -format UDZO "build/OwnVoice-Meet-${version}-mac-arm64.dmg"
ls -la build/*.dmg
