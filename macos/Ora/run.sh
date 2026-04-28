#!/bin/bash
# Build Ora via xcodebuild (SwiftPM can't compile Metal shaders), assemble a
# proper .app bundle, then run the binary directly from inside it. Direct
# launch keeps stdio connected to the terminal and avoids LaunchServices
# caching of old instances.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DERIVED="$HERE/.xcode-build"
PRODUCTS="$DERIVED/Build/Products/Release"
BINARY="$PRODUCTS/ora"        # SwiftPM product name
APP_DIR="$HERE/.app/Ora.app"

# ── Kill only the local generated app instance ─────────────────────────
pkill -f "$APP_DIR/Contents/MacOS/ora" 2>/dev/null || true

# ── Build ──────────────────────────────────────────────────────────────
needs_build=false
if [ ! -x "$BINARY" ]; then
    needs_build=true
elif find "$HERE/Sources/Ora" "$HERE/Resources" -type f -newer "$BINARY" -print -quit | grep -q .; then
    needs_build=true
elif [ "$HERE/Info.plist" -nt "$BINARY" ] || [ "$HERE/Ora.entitlements" -nt "$BINARY" ]; then
    needs_build=true
fi

if [ "$needs_build" = true ]; then
    echo "[build] xcodebuild Release..."
    xcodebuild \
        -workspace "$HERE" \
        -scheme Ora \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" \
        build \
        -quiet
fi

# ── Assemble Ora.app ───────────────────────────────────────────────────
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# Rename binary to match Info.plist's CFBundleExecutable.
cp "$BINARY" "$APP_DIR/Contents/MacOS/ora"

for b in "$PRODUCTS"/*.bundle; do
    [ -d "$b" ] || continue
    cp -R "$b" "$APP_DIR/Contents/Resources/"
done

cp "$HERE/Info.plist" "$APP_DIR/Contents/Info.plist"

if [ -f "$HERE/Resources/AppIcon.icns" ]; then
    cp "$HERE/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo "[run] bundle assembled at $APP_DIR"
echo "[run] launching binary directly — stdio stays connected"
echo "------------------------------------------------------------"

exec "$APP_DIR/Contents/MacOS/ora" "$@"
