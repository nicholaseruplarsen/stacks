#!/bin/zsh
# Packages build/Stacks.app into build/Stacks-<version>.dmg with an Applications shortcut to drag it onto.
set -euo pipefail
cd "${0:A:h}"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Stacks.app/Contents/Info.plist)
STAGE=build/dmg
DMG=build/Stacks-$VERSION.dmg
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
cp -R build/Stacks.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Stacks $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "built $DMG"
