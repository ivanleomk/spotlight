#!/bin/bash
# Builds the debug version as .build/Spotlight.app, for `make run`.
#
# Why not just run the bare program? macOS finds an app's name, icon and
# identity through its .app folder. A bare program has none, so system prompts
# call it "(null)", and the Keychain can't recognise it between builds.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
APP=.build/Spotlight.app
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/Spotlight "$APP/Contents/MacOS/Spotlight"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Signing with a real certificate gives the app a stable identity, so a
# Keychain "Always Allow" survives rebuilds. Without one, sign "ad hoc" (-).
IDENTITY="$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)"
codesign --force --sign "${IDENTITY:--}" "$APP" 2>/dev/null
echo "$APP"
