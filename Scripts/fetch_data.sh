#!/bin/sh
# Downloads the prebuilt data files into Populus/Resources/Data.
# They are too big for git, so they live on the GitHub Release tagged data-v1.
set -eu
URL="https://github.com/gxlactuss/Populus/releases/download/data-v1/populus-data.zip"

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fL --progress-bar -o "$tmp/data.zip" "$URL"
mkdir -p Populus/Resources/Data
unzip -oq "$tmp/data.zip" -d Populus/Resources/Data
echo "Data ready in Populus/Resources/Data"
