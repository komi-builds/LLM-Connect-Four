#!/bin/zsh
# Builds a Release app and packages it as a DMG and a zip in build/dist/.
#
#   Scripts/package.sh
#
# The app is ad hoc signed (no Apple Developer account), so it runs on this Mac as is.
# On another Mac, Gatekeeper blocks the first launch: right-click the app and choose Open,
# or allow it in System Settings > Privacy & Security. Notarizing needs a Developer ID.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=Release Scripts/xc.sh build
app=build/DerivedData/Build/Products/Release/LLMConnectFour.app
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
dist=build/dist
name="LLMConnectFour-$version"
mkdir -p "$dist"
rm -rf "$dist/$name.dmg" "$dist/$name.zip" "$dist/stage"

codesign --verify --deep --strict "$app"

# Zip (keeps signatures and symlinks).
ditto -c -k --keepParent "$app" "$dist/$name.zip"

# DMG with an Applications shortcut to drag onto.
mkdir -p "$dist/stage"
ditto "$app" "$dist/stage/LLM Connect Four.app"
ln -s /Applications "$dist/stage/Applications"
hdiutil create -quiet -volname "LLM Connect Four $version" -srcfolder "$dist/stage" \
  -fs APFS -format ULFO "$dist/$name.dmg"
rm -rf "$dist/stage"

ls -lh "$dist/$name.dmg" "$dist/$name.zip"
