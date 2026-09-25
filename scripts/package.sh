#!/bin/bash
# Builds Spotlight.app and zips it for a GitHub release.
#
#   scripts/package.sh 0.1.0
#
# SwiftPM only builds a bare executable. A real Mac app is a folder with a fixed
# layout (a "bundle"): the executable in Contents/MacOS, and an Info.plist that
# tells macOS the app's name, id and settings. We assemble that by hand.
#
# Signing: uses the first "Developer ID Application" certificate in your keychain
# (override with SIGN_IDENTITY). Notarizing: set NOTARY_PROFILE to a profile made
# with `xcrun notarytool store-credentials`; without it the app is signed but not
# notarized, and macOS will ask users to approve it in System Settings.
set -euo pipefail

VERSION="${1:?usage: scripts/package.sh <version>}"
cd "$(dirname "$0")/.."

DIST=dist
APP="$DIST/Spotlight.app"
ZIP="$DIST/Spotlight-$VERSION-macos.zip"

# One binary that runs natively on both Apple Silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/Spotlight"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Spotlight"

# The same Info.plist the dev build embeds, with the release version filled in.
cp Support/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.ivanleomk.spotlight</string>
    <key>CFBundleName</key><string>Spotlight</string>
    <key>CFBundleExecutable</key><string>Spotlight</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSDocumentsFolderUsageDescription</key><string>Spotlight indexes your Documents so you can search them.</string>
    <key>NSDesktopFolderUsageDescription</key><string>Spotlight indexes your Desktop so you can search it.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Spotlight indexes your Downloads so you can search them.</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"' || true)}"
if [ -n "$IDENTITY" ]; then
    # --options runtime = the "hardened runtime", which notarization requires.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    echo "No Developer ID certificate found; signing ad hoc (users will see a warning)."
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

# ditto (not zip) keeps the bundle's metadata and signature intact.
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    # "Staple" the approval into the app so it opens even offline, then re-zip.
    xcrun stapler staple "$APP"
    rm "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "Built $ZIP"
