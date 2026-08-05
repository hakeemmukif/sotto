#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Sotto"
BUNDLE="$APP_NAME.app"
IDENTITY="Sotto Dev"

swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

codesign -f -s "$IDENTITY" --options runtime --entitlements Resources/Sotto.entitlements "$BUNDLE"

DR="$(codesign -dr - "$BUNDLE")"
echo "$DR"

if ! echo "$DR" | grep -q 'certificate root = H"a22ef0b5e30d5b9650c2b0db015badb15e924a7c"'; then
    echo "error: designated requirement does not match Sotto Dev identity" >&2
    exit 1
fi
