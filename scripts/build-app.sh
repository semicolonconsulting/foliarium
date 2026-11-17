#!/usr/bin/env bash
# Builds build/Foliarium.app. Needs Xcode 16 or later.
#
# Signs with your "Apple Development" certificate when the keychain has one, so macOS keeps folder
# permissions (Desktop, Documents, Downloads) across rebuilds. Otherwise signs ad-hoc.
# Override with SIGN_IDENTITY, e.g. SIGN_IDENTITY=- for ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-Release}"
TEAM_ID="${TEAM_ID:-C6ZRF9KM22}"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-identity -v -p codesigning | grep -q "Apple Development"; then
        SIGN_IDENTITY="Apple Development"
    else
        SIGN_IDENTITY="-"
    fi
fi
echo "Signing with: $SIGN_IDENTITY"
DERIVED="build/DerivedData"

mkdir -p build
LOG="build/xcodebuild.log"
if ! xcodebuild build \
    -project Foliarium.xcodeproj \
    -scheme Foliarium \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    > "$LOG" 2>&1; then
    grep -E "error|failed|Failed" "$LOG" | tail -40 >&2
    echo "Build failed; full log in $LOG" >&2
    exit 1
fi
grep -E "warning:|BUILD SUCCEEDED" "$LOG" | grep -v "Metadata extraction skipped" || true

APP="$DERIVED/Build/Products/$CONFIG/Foliarium.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found" >&2; exit 1; }

rm -rf build/Foliarium.app
ditto "$APP" build/Foliarium.app
echo "Built build/Foliarium.app"
