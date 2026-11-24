#!/usr/bin/env bash
# Builds the App Store edition: sandboxed, without "Delete files in Trash" or the updater, signed for the Mac App Store.
# Makes build/appstore/Foliarium.pkg, or uploads it to App Store Connect with UPLOAD=1.
#
# Needs the app record for com.semicolonc.foliarium in App Store Connect, and Xcode signed in to the team's
# Apple account (Xcode → Settings → Accounts), so it can make the App Store provisioning profile.
# Each upload needs a new build number: bump CURRENT_PROJECT_VERSION, or set BUILD_NUMBER.
set -euo pipefail

cd "$(dirname "$0")/.."
TEAM_ID="${TEAM_ID:-C6ZRF9KM22}"
ARCHIVE="build/Foliarium-AppStore.xcarchive"
OUT="build/appstore"
LOG="build/appstore.log"
mkdir -p build

EXTRA=()
[[ -n "${BUILD_NUMBER:-}" ]] && EXTRA+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

rm -rf "$ARCHIVE" "$OUT"
echo "Archiving the App Store edition"
if ! xcodebuild archive \
    -project Foliarium.xcodeproj \
    -scheme Foliarium \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_APP_SANDBOX=YES \
    CODE_SIGN_ENTITLEMENTS=Config/Foliarium-AppStore.entitlements \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APPSTORE' \
    ${EXTRA[@]+"${EXTRA[@]}"} \
    > "$LOG" 2>&1; then
    grep -E "error|failed|Failed" "$LOG" | tail -40 >&2
    echo "Archive failed; full log in $LOG" >&2
    exit 1
fi

OPTIONS="build/ExportOptions-AppStore.plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$([[ "${UPLOAD:-}" == "1" ]] && echo upload || echo export)</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "Exporting$([[ "${UPLOAD:-}" == "1" ]] && echo " and uploading to App Store Connect")"
if ! xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OPTIONS" \
    -exportPath "$OUT" \
    -allowProvisioningUpdates \
    >> "$LOG" 2>&1; then
    grep -E "error|failed|Failed" "$LOG" | tail -40 >&2
    echo "Export failed; full log in $LOG" >&2
    exit 1
fi

APP="$ARCHIVE/Products/Applications/Foliarium.app"
echo "Entitlements:"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - || true
if [[ "${UPLOAD:-}" == "1" ]]; then
    echo "Uploaded. The build shows in App Store Connect → TestFlight once Apple has processed it."
else
    ls "$OUT"
    echo "Built $OUT. Run with UPLOAD=1 to send it to App Store Connect."
fi
