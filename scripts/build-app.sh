#!/bin/bash
# Builds OpenTouch.app into ./build.
#
#   scripts/build-app.sh                 ad-hoc signed (fine for your own Mac)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   UNIVERSAL=1 scripts/build-app.sh     arm64 + x86_64 (needs full Xcode)
#
# macOS ties the Accessibility permission to the code signature. With ad-hoc
# signing you have to re-enable OpenTouch in System Settings after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
APP=build/OpenTouch.app

ARCH_FLAGS=()
[ "${UNIVERSAL:-0}" = 1 ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)/OpenTouch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenTouch"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($VERSION)"
