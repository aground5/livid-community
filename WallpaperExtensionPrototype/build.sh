#!/bin/bash
# Builds and signs the prototype host app with the embedded wallpaper extension.
set -euo pipefail
cd "$(dirname "$0")"
IDENTITY="${IDENTITY:-Apple Development}"
APP=build/LividWallpaperPrototype.app
EXT=$APP/Contents/Extensions/LividWallpaperExtension.appex
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
swiftc -parse-as-library -target arm64-apple-macos27.0 -O -I PrivateSDK Sources/LividWallpaperExtension.swift \
  PrivateSDK/WallpaperExtensionKit.tbd PrivateSDK/WallpaperTypes.tbd -framework ExtensionFoundation \
  -application-extension -Xlinker -e -Xlinker _NSExtensionMain -o "$EXT/Contents/MacOS/LividWallpaperExtension"
swiftc -target arm64-apple-macos27.0 -O Sources/HostApp.swift -o "$APP/Contents/MacOS/LividWallpaperPrototype"
cp Resources/livid-test.mov Resources/livid-thumb.png "$EXT/Contents/Resources/"
cp Info/Extension-Info.plist "$EXT/Contents/Info.plist"
cp Info/Host-Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --entitlements Info/Extension.entitlements --timestamp=none "$EXT"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo "built $APP"
