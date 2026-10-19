#!/bin/zsh
# Builds "build/do clean.app" (Tools/bundle.sh) and packs it into dist/doclean-<version>.dmg
# (app + /Applications symlink) with a .sha256 next to it. Publishes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/DoCleanCore/DoCleanCore.swift)
APP="build/do clean.app"
DMG="dist/doclean-$VERSION.dmg"

Tools/bundle.sh
[[ -d "$APP" ]] || { echo "missing $APP" >&2; exit 1 }
codesign --verify --deep --strict "$APP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "do clean $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
(cd dist && shasum -a 256 "doclean-$VERSION.dmg" > "doclean-$VERSION.dmg.sha256")
echo "dmg:    $DMG ($(du -h "$DMG" | cut -f1))"
echo "sha256: $(cut -d' ' -f1 "$DMG.sha256")"
