#!/bin/zsh
# Builds Stacks.app with the Command Line Tools only (no Xcode, no SwiftPM).
# Uses the macOS 26 SDK: in the 27 SDK SwiftUI's @State is a macro whose plugin ships only with Xcode.
set -euo pipefail
cd "${0:A:h}"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
APP=build/Stacks.app
OBJ=build/obj
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$OBJ"
clang -O2 -c -isysroot $SDK -target arm64-apple-macos14.0 Sources/Stacks/hw.c -o $OBJ/hw.o
swiftc -sdk $SDK -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Sources/Stacks/hw.h \
  -framework IOKit -framework SystemConfiguration -framework ServiceManagement -lIOReport \
  Sources/Stacks/*.swift $OBJ/hw.o -o "$APP/Contents/MacOS/Stacks"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Stacks</string>
  <key>CFBundleIdentifier</key><string>com.nicholaseruplarsen.stacks</string>
  <key>CFBundleName</key><string>Stacks</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP"
