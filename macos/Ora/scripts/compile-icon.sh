#!/bin/bash
# Compile the approved layered icon and its menu bar template into a bundle.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:?Usage: compile-icon.sh <bundle-resources-directory>}"
mkdir -p "$OUTPUT"
PARTIAL="$(mktemp -t ora-icon-info)"
trap 'rm -f "$PARTIAL"' EXIT

xcrun actool "$HERE/Resources/AppIcon.icon" \
    --compile "$OUTPUT" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --include-all-app-icons \
    --output-partial-info-plist "$PARTIAL" \
    --output-format human-readable-text

cp "$HERE/Resources/MenuBarIcon.pdf" "$OUTPUT/MenuBarIcon.pdf"
