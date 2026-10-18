#!/bin/sh
# Builds Populus.app in Release and packages it (zip and DMG) and the data files into dist/ for a GitHub Release.
set -eu

cd "$(dirname "$0")/.."
version=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
xcodegen generate -q
xcodebuild -project Populus.xcodeproj -scheme Populus -configuration Release -destination "generic/platform=macOS" -derivedDataPath build clean build -quiet
rm -rf dist
mkdir -p dist
ditto -c -k --keepParent build/Build/Products/Release/Populus.app "dist/Populus-$version.zip"
# The DMG opens to a themed window with the app and an Applications shortcut to drag it onto.
# Needs create-dmg (brew install create-dmg). Icon positions must match make_dmg_background.swift.
stage=$(mktemp -d)
art=$(mktemp -d)
cp -R build/Build/Products/Release/Populus.app "$stage/"
swift Scripts/make_dmg_background.swift "$art"
tiffutil -cathidpicheck "$art/background.png" "$art/background@2x.png" -out "$art/background.tiff" 2>/dev/null
create-dmg --volname Populus --background "$art/background.tiff" --window-size 660 400 --icon-size 128 \
    --icon Populus.app 180 180 --app-drop-link 480 180 \
    "dist/Populus-$version.dmg" "$stage" >/dev/null
rm -rf "$stage" "$art"
(cd Populus/Resources/Data && zip -qr ../../../dist/populus-data.zip .)
ls -lh dist
