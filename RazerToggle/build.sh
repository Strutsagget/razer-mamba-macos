#!/bin/zsh
# Bygger RazerToggle.app (native arm64) och installerar i /Applications.
set -e
cd "${0:A:h}"

APP=build/RazerToggle.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/RazerToggle" main.swift -framework AppKit

# Ikon: rita PNG om den saknas, skala till alla storlekar och packa som .icns
[[ -f icon.png ]] || swift makeicon.swift icon.png
mkdir -p "$APP/Contents/Resources" build/AppIcon.iconset
for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>RazerToggle</string>
    <key>CFBundleIdentifier</key><string>se.pija.razertoggle</string>
    <key>CFBundleExecutable</key><string>RazerToggle</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

rm -rf /Applications/RazerToggle.app
cp -R "$APP" /Applications/
echo "Installerad: /Applications/RazerToggle.app"
