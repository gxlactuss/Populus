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
# The DMG opens to a window with the app and an Applications shortcut to drag it onto.
stage=$(mktemp -d)
cp -R build/Build/Products/Release/Populus.app "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname Populus -srcfolder "$stage" -format UDZO "dist/Populus-$version.dmg"
rm -rf "$stage"
(cd Populus/Resources/Data && zip -qr ../../../dist/populus-data.zip .)
ls -lh dist
