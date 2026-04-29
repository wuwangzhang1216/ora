#!/bin/bash
# Build a distributable Ora.dmg.
#
# Usage:
#   ./package.sh                      # ad-hoc sign (works locally, not for others)
#   ./package.sh --developer-id       # sign with Developer ID + notarize
#
# For --developer-id you need:
#   - an Apple Developer Program membership ($99/yr)
#   - a "Developer ID Application" certificate in Keychain
#   - an app-specific password stored as a keychain profile:
#       xcrun notarytool store-credentials "ora-notary" \
#           --apple-id you@example.com \
#           --team-id XXXXXXXXXX \
#           --password <app-specific-password>

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DERIVED="$HERE/.xcode-build"
PRODUCTS="$DERIVED/Build/Products/Release"
BINARY="$PRODUCTS/ora"
DIST_DIR="$HERE/.dist"
APP_DIR="$DIST_DIR/Ora.app"
DMG_PATH="$DIST_DIR/Ora.dmg"

SIGN_MODE="adhoc"
DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ora-notary}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --developer-id) SIGN_MODE="developer-id"; shift;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

# ── Build ──────────────────────────────────────────────────────────────
echo "[pkg] building release..."
xcodebuild \
    -workspace "$HERE" \
    -scheme Ora \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    build \
    -quiet

# ── Assemble Ora.app ───────────────────────────────────────────────────
echo "[pkg] assembling Ora.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/ora"

for b in "$PRODUCTS"/*.bundle; do
    [ -d "$b" ] || continue
    cp -R "$b" "$APP_DIR/Contents/Resources/"
done

cp "$HERE/Info.plist" "$APP_DIR/Contents/Info.plist"

if [ -f "$HERE/Resources/AppIcon.icns" ]; then
    cp "$HERE/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# ── Sign ───────────────────────────────────────────────────────────────
if [ "$SIGN_MODE" = "adhoc" ]; then
    echo "[pkg] ad-hoc signing (local use only)..."
    codesign --deep --force --sign - \
        --options runtime \
        --entitlements "$HERE/Ora.entitlements" \
        "$APP_DIR" 2>&1 | tail -5 || {
            codesign --deep --force --sign - "$APP_DIR"
        }
else
    if [ -z "$DEVELOPER_ID" ]; then
        echo "[pkg] ERROR: DEVELOPER_ID env var not set" >&2
        echo '  Example: DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./package.sh --developer-id' >&2
        exit 1
    fi
    echo "[pkg] signing with $DEVELOPER_ID..."
    codesign --deep --force --sign "$DEVELOPER_ID" \
        --options runtime \
        --timestamp \
        --entitlements "$HERE/Ora.entitlements" \
        "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -5
echo "[pkg] .app signed"

# ── Create DMG ─────────────────────────────────────────────────────────
echo "[pkg] creating $DMG_PATH..."
rm -f "$DMG_PATH"

STAGING="$DIST_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Ora" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" \
    >/dev/null

rm -rf "$STAGING"

if [ "$SIGN_MODE" = "developer-id" ]; then
    echo "[pkg] signing DMG with $DEVELOPER_ID..."
    codesign --force --sign "$DEVELOPER_ID" \
        --timestamp \
        "$DMG_PATH"
fi

echo "[pkg] DMG: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

# ── Notarize (if profile present) ──────────────────────────────────────
if [ "$SIGN_MODE" = "developer-id" ]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "[pkg] submitting for notarization (profile: $NOTARY_PROFILE)..."
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait

        echo "[pkg] stapling notarization ticket..."
        xcrun stapler staple "$DMG_PATH"
        xcrun stapler staple "$APP_DIR"
    else
        cat >&2 <<EOF
[pkg] ⚠ Notary profile "$NOTARY_PROFILE" not found — skipping notarization.
      DMG is signed but unnotarized. Gatekeeper will warn on first open.
      To enable notarization, run once:

        xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
            --apple-id YOUR_APPLE_ID \\
            --team-id 46KF5Z549N \\
            --password YOUR_APP_SPECIFIC_PASSWORD

      Get an app-specific password at https://appleid.apple.com/account/manage
EOF
    fi
fi

echo
echo "✅ Done. Distribute: $DMG_PATH"
