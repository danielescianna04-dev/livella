#!/bin/zsh
# Builds Livella.app next to this script and signs it ad hoc for this Mac.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="Livella.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Livella "$APP/Contents/MacOS/Livella"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
