#!/usr/bin/env bash
# Makes a drag-to-install disk image of an app, with the designed window from Design/dmg/:
#   scripts/make-dmg.sh build/Foliarium.app build/Foliarium-1.1.dmg
# Uses dmgbuild (https://github.com/dmgbuild/dmgbuild), installed into build/.dmgbuild-venv on the
# first run, which writes the window layout without driving Finder. Doesn't sign the image.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:?usage: make-dmg.sh <app> <dmg>}"
DMG="${2:?usage: make-dmg.sh <app> <dmg>}"
VENV="build/.dmgbuild-venv"

if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
    echo "Installing dmgbuild into $VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet "dmgbuild>=1.6.5"
fi

# The window title, like "Foliarium 1.1".
NAME=$(basename "$APP" .app)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || true)
ICON="$APP/Contents/Resources/AppIcon.icns"
[[ -f "$ICON" ]] || ICON=""
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py \
    -D app="$APP" -D volume_icon="$ICON" -D repo="$PWD" \
    "$NAME${VERSION:+ $VERSION}" "$DMG"
echo "Made $DMG"
