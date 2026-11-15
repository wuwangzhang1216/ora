#!/bin/bash
# Build a distributable Ora.dmg.
#
# Usage:
#   ./package.sh                      # ad-hoc sign (works locally, not for others)
#   ./package.sh --developer-id       # sign with Developer ID + notarize
#   ./package.sh --developer-id --sandbox # local App Sandbox validation bundle
#   ./package.sh --app-store --prepare-only # production-ID sandbox candidate, NOT uploadable
#   ./package.sh --app-store # requires App Store signing identities + profile
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
SIGN_MODE="adhoc"
SANDBOX=false
APP_STORE=false
PREPARE_ONLY=false
DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ora-notary}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --developer-id) SIGN_MODE="developer-id"; shift;;
        --sandbox) SANDBOX=true; shift;;
        --app-store) APP_STORE=true; shift;;
        --prepare-only) PREPARE_ONLY=true; shift;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

if [ "$PREPARE_ONLY" = true ] && [ "$APP_STORE" != true ]; then
    echo "[pkg] --prepare-only requires --app-store" >&2; exit 1
fi
if [ "$APP_STORE" = true ]; then
    if [ "$SANDBOX" = true ] || [ "$SIGN_MODE" != adhoc ]; then
        echo "[pkg] --app-store cannot be combined with --sandbox or --developer-id" >&2; exit 1
    fi
    if [ "$PREPARE_ONLY" != true ]; then
        : "${APP_STORE_APPLICATION_IDENTITY:?Set an Apple Distribution or Mac App Distribution signing identity}"
        : "${APP_STORE_INSTALLER_IDENTITY:?Set a Mac Installer Distribution signing identity}"
        : "${APP_STORE_PROFILE:?Set the path to an App Store macOS provisioning profile}"
        case "$APP_STORE_APPLICATION_IDENTITY" in
            "Apple Distribution:"*|"3rd Party Mac Developer Application:"*|"Mac App Distribution:"*) ;;
            *) echo "[pkg] App Store application signing identity required" >&2; exit 1;;
        esac
        case "$APP_STORE_INSTALLER_IDENTITY" in
            "3rd Party Mac Developer Installer:"*|"Mac Installer Distribution:"*) ;;
            *) echo "[pkg] App Store installer signing identity required" >&2; exit 1;;
        esac
        [ -f "$APP_STORE_PROFILE" ] || { echo "[pkg] Provisioning profile not found" >&2; exit 1; }
    fi
fi

DIST_DIR="$HERE/.dist"
ENTITLEMENTS="$HERE/Ora.entitlements"
APP_NAME="Ora"
if [ "$SANDBOX" = true ]; then
    DIST_DIR="$HERE/.sandbox"
    ENTITLEMENTS="$HERE/OraSandbox.entitlements"
    APP_NAME="Ora Sandbox"
fi
if [ "$APP_STORE" = true ]; then
    DIST_DIR="$HERE/.app-store"
    ENTITLEMENTS="$HERE/OraSandbox.entitlements"
fi
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/Ora.dmg"

# ── Build ──────────────────────────────────────────────────────────────
echo "[pkg] building release..."
xcodebuild \
    -workspace "$HERE" \
    -scheme Ora \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation \
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
cp "$HERE/Resources/PrivacyInfo.xcprivacy" "$APP_DIR/Contents/Resources/"
python3 "$HERE/scripts/third-party-notices.py" "$DERIVED/SourcePackages/checkouts" \
    "$APP_DIR/Contents/Resources/ThirdPartyNotices.txt"
if [ "$SANDBOX" = true ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.wangzhangwu.ora.sandbox' "$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_DIR/Contents/Info.plist"
fi

if [ "$APP_STORE" = true ] && [ "$PREPARE_ONLY" != true ]; then
    cp "$APP_STORE_PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
    security cms -D -i "$APP_STORE_PROFILE" > "$DIST_DIR/profile.plist"
    python3 "$HERE/scripts/store-entitlements.py" "$DIST_DIR/profile.plist" \
        "$ENTITLEMENTS" "$DIST_DIR/store.entitlements"
    rm "$DIST_DIR/profile.plist"
    ENTITLEMENTS="$DIST_DIR/store.entitlements"
    SIGN_MODE="app-store"
    DEVELOPER_ID="$APP_STORE_APPLICATION_IDENTITY"
fi

bash "$HERE/scripts/compile-icon.sh" "$APP_DIR/Contents/Resources"

# ── Sign ───────────────────────────────────────────────────────────────
if [ "$SIGN_MODE" = "adhoc" ]; then
    echo "[pkg] ad-hoc signing (local use only)..."
    codesign --deep --force --sign - \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        "$APP_DIR" 2>&1 | tail -5 || {
            codesign --deep --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
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
        --entitlements "$ENTITLEMENTS" \
        "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -5
if [ "$SIGN_MODE" = "app-store" ]; then
    PROFILE_TEAM=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$ENTITLEMENTS")
    SIGNER_TEAM=$(codesign -dv "$APP_DIR" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    if [ "$SIGNER_TEAM" != "$PROFILE_TEAM" ]; then
        echo "[pkg] Signing certificate and provisioning profile belong to different teams" >&2; exit 1
    fi
fi
echo "[pkg] .app signed"

if [ "$APP_STORE" = true ]; then
    if [ "$PREPARE_ONLY" = true ]; then
        echo "[pkg] LOCAL CANDIDATE ONLY (ad-hoc signed, no App Store profile): $APP_DIR"
        echo "[pkg] This bundle cannot be uploaded. Run --app-store with distribution credentials when available."
    else
        productbuild --component "$APP_DIR" /Applications \
            --sign "$APP_STORE_INSTALLER_IDENTITY" "$DIST_DIR/Ora.pkg"
        pkgutil --check-signature "$DIST_DIR/Ora.pkg"
        echo "[pkg] Signed App Store package: $DIST_DIR/Ora.pkg"
        echo "[pkg] Validate and upload with Transporter; Apple processing and review are still required."
    fi
    exit 0
fi

if [ "$SANDBOX" = true ]; then
    echo "[pkg] Local sandbox validation bundle: $APP_DIR"
    echo "[pkg] App Store distribution signing and submission are separate steps."
    exit 0
fi

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
    if NOTARY_CHECK_OUTPUT="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
        echo "[pkg] submitting for notarization (profile: $NOTARY_PROFILE)..."
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait

        echo "[pkg] stapling notarization ticket..."
        xcrun stapler staple "$DMG_PATH"
        xcrun stapler staple "$APP_DIR"
    else
        printf '%s\n' "$NOTARY_CHECK_OUTPUT" >&2
        echo "[pkg] Notarization unavailable for profile '$NOTARY_PROFILE'." >&2
        echo "[pkg] DMG is signed but NOT notarized; macOS may block first launch." >&2
        echo "[pkg] Resolve the Apple error above before distributing it as notarized." >&2
    fi
fi

echo
echo "✅ Done. Distribute: $DMG_PATH"
