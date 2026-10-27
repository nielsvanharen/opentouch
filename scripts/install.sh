#!/bin/bash
# Builds OpenTouch, installs it in /Applications and starts it.
# The first launch from /Applications turns on Open at Login.
#
#   scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

osascript -e 'quit app "OpenTouch"' 2>/dev/null || true
pkill -x OpenTouch 2>/dev/null || true

rm -rf /Applications/OpenTouch.app
ditto build/OpenTouch.app /Applications/OpenTouch.app
xattr -dr com.apple.quarantine /Applications/OpenTouch.app 2>/dev/null || true

open /Applications/OpenTouch.app
echo "Installed /Applications/OpenTouch.app"
