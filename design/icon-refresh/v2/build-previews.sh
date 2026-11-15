#!/bin/zsh
set -euo pipefail
here="${0:A:h}"
swift "$here/prepare.swift"
swiftc "$here/IconPreview.swift" -o "$here/.preview/IconPreview"
for app in "$here"/.preview/*.app; do
    cp "$here/.preview/IconPreview" "$app/Contents/MacOS/IconPreview"
    codesign --force --sign - "$app"
done
