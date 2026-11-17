#!/bin/sh
# Builds DimHidden.app (universal) and installs it to ~/Applications.
set -eu
cd "$(dirname "$0")"

APP=build/DimHidden.app
IDENTITY="${SIGN_IDENTITY:-DimHidden Local Signing}"

rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos14" Sources/main.swift -o "build/DimHidden-$arch"
done
lipo -create build/DimHidden-arm64 build/DimHidden-x86_64 -output "$APP/Contents/MacOS/DimHidden"
rm build/DimHidden-arm64 build/DimHidden-x86_64

# macOS ties the Accessibility permission to the app's signature. An ad-hoc signature changes on every build,
# so with one you have to re-allow DimHidden after each rebuild. A named identity keeps it stable.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier com.johann.DimHidden "$APP"
else
  echo "Signing identity '$IDENTITY' not found, signing ad-hoc." >&2
  codesign --force --sign - --identifier com.johann.DimHidden "$APP"
fi

if [ "${1:-}" != "--no-install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/DimHidden.app"
  cp -R "$APP" "$HOME/Applications/DimHidden.app"
  echo "Installed to ~/Applications/DimHidden.app"
fi
