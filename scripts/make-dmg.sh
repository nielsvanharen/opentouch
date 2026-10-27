#!/bin/bash
# Packages build/OpenTouch.app into a disk image with an Applications shortcut,
# so it installs like any other Mac app: open the image, drag OpenTouch to Applications.
#
#   scripts/make-dmg.sh OpenTouch-v1.0.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/OpenTouch.dmg}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto build/OpenTouch.app "$STAGE/OpenTouch.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname OpenTouch -srcfolder "$STAGE" -format UDZO -ov "$OUT" >/dev/null
echo "Created $OUT"
