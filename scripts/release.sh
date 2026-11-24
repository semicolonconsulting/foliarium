#!/usr/bin/env bash
# Builds a release: build/Foliarium-<version>.dmg, signed with Developer ID, notarized and stapled.
#
# Needs a "Developer ID Application" certificate in the keychain and a notarytool keychain profile,
# made once with:
#   xcrun notarytool store-credentials notary --apple-id <Apple ID> --team-id <team> --password <app-specific password>
# Override with NOTARY_PROFILE, TEAM_ID or SIGN_IDENTITY.
set -euo pipefail

cd "$(dirname "$0")/.."
TEAM_ID="${TEAM_ID:-C6ZRF9KM22}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
export TEAM_ID SIGN_IDENTITY

security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
    || { echo "No \"$SIGN_IDENTITY\" certificate in the keychain" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null \
    || { echo "The notarytool profile \"$NOTARY_PROFILE\" doesn't work; see the top of this script" >&2; exit 1; }

./scripts/build-app.sh
APP="build/Foliarium.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
echo "Releasing Foliarium $VERSION ($BUILD)"

# Re-sign with a secure timestamp and the hardened runtime, which notarization requires.
# Nested code first, then the app.
find "$APP/Contents" -depth \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" -o -name "*.appex" -o -name "*.app" \) -print0 \
    | while IFS= read -r -d '' item; do
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
    done
# Keep the app's entitlements, minus get-task-allow: Xcode adds that for debugging, and notarization rejects it.
ENTITLEMENTS="build/Foliarium.entitlements"
codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null || true
[[ -s "$ENTITLEMENTS" ]] || echo '<plist version="1.0"><dict/></plist>' > "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENTITLEMENTS" 2>/dev/null || true
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
rm -f "$ENTITLEMENTS"
codesign --verify --deep --strict --verbose=2 "$APP"

# Sends a file to Apple's notary service, waits for the verdict and prints the log if it's rejected.
notarize() {
    local file="$1" out id
    out=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
    echo "$out"
    if ! grep -q "status: Accepted" <<< "$out"; then
        id=$(sed -nE 's/^ *id: ([0-9a-f-]+).*/\1/p' <<< "$out" | head -1)
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        echo "Notarization of $file failed" >&2
        exit 1
    fi
}

# Notarize and staple the app itself, so it opens without a network check once copied out of the DMG.
ZIP="build/Foliarium-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple "$APP"

# The disk image: the app and a link to Applications to drag it onto, in the designed window.
DMG="build/Foliarium-$VERSION.dmg"
./scripts/make-dmg.sh "$APP" "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
shasum -a 256 "$DMG"
echo "Built $DMG"
