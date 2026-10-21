#!/bin/zsh
# Construit « nEXUSWATCH.app » (dossier du projet), signé avec le certificat stable (_tools/sign_app.sh).
set -euo pipefail
cd "$(dirname "$0")"
APP="nEXUSWATCH.app"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos14 -o build/NexusWatch-$arch Sources/*.swift
done
lipo -create build/NexusWatch-arm64 build/NexusWatch-x86_64 -output "$APP/Contents/MacOS/NexusWatch"

swift Resources/make_icon.swift build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
rm -rf build
"$(cd .. && pwd)/_tools/sign_app.sh" "$APP"
echo "OK : $APP"
[ -n "${NO_OPEN:-}" ] || open "$APP"
