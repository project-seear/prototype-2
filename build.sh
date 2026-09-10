#!/bin/bash
# Builds Prototype2.app.
#
# CoreMotion will only hand out headphone orientation to a code-signed app bundle
# that declares NSMotionUsageDescription, so a bare SwiftPM executable is not
# enough — this script assembles and signs the bundle.
#
# Set CODESIGN_ID to a real identity (e.g. "Apple Development: you@example.com")
# to keep the motion permission across rebuilds. With the default ad-hoc "-"
# signature the code hash changes on every build, so macOS may re-ask for
# Motion & Fitness access after a rebuild.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
SIGN_ID="${CODESIGN_ID:--}"
APP="build/Prototype2.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Prototype2"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Prototype2"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> codesign (identity: $SIGN_ID)"
codesign --force --options runtime --identifier com.seear.prototype2 \
         --sign "$SIGN_ID" "$APP" 2>&1 | sed 's/^/    /'

echo "==> built $APP"
