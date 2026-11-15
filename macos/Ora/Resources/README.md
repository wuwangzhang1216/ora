# Ora icon

The approved A3 folded-caption design is the canonical `AppIcon.icon` document.
Edit its two vector layers in Icon Composer. Native materials and enclosure are
rendered by Apple, without baked tile corners or extra legacy padding.

Both local and distribution packaging use `scripts/compile-icon.sh`, which emits
`Assets.car`, a compatibility `AppIcon.icns`, and the menu bar PDF template. The
bundle declares `CFBundleIconName = AppIcon` for native appearance support.

`MenuBarIcon.svg` is the same two shapes in one color, framed for an 18-point
menu bar image. Its vector PDF is committed for builds without extra tools.

Regenerate the committed compatibility icon with:

```sh
swift macos/Ora/Resources/generate-icon.swift
```

If the menu bar vector changes, regenerate its PDF with `rsvg-convert -f pdf`.
The app loads it as a template so macOS controls the light/dark color.
