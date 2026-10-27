#!/bin/sh
# Builds Pondside.app from the SwiftPM products (macOS only).
#   scripts/make-app.sh [debug|release]   → .build/Pondside.app
set -eu
cd "$(dirname "$0")/.."
config="${1:-release}"
swift build -c "$config" --product PondsideApp
swift build -c "$config" --product pondside
bin="$(swift build -c "$config" --show-bin-path)"
app=".build/Pondside.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/PondsideApp" "$app/Contents/MacOS/Pondside"
cp "$bin/pondside" "$app/Contents/Resources/pondside"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pondside</string>
  <key>CFBundleDisplayName</key><string>Pondside</string>
  <key>CFBundleIdentifier</key><string>app.pondside.Pondside</string>
  <key>CFBundleExecutable</key><string>Pondside</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>LilyPond Source</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>ly</string><string>ily</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "$app"
