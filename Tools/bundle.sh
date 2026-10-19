#!/bin/zsh
# Build release and wrap it into "build/do clean.app" with ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/DoCleanCore/DoCleanCore.swift)
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP="build/do clean.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DoCleanApp" "$APP/Contents/MacOS/DoClean"
cp "$BIN/doclean" "$APP/Contents/Resources/doclean"
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>do clean</string>
  <key>CFBundleDisplayName</key><string>do clean</string>
  <key>CFBundleIdentifier</key><string>app.do.clean</string>
  <key>CFBundleExecutable</key><string>DoClean</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
echo "built: $APP ($VERSION)"
