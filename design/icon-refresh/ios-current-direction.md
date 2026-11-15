# Current iOS icon direction — correction to the raster studies

The owner rejected treating the oversized concepts as only a padding problem.
The v2 80% measurement matches one legacy macOS Finder resource; it is **not an
iOS icon production specification**, nor a universal foreground-size rule.

## Verified official references

- [Current iOS overview](https://www.apple.com/os/ios/) identifies iOS 27.
- [Apple app-icon HIG](https://developer.apple.com/design/human-interface-guidelines/app-icons):
  imported background artwork should be full-bleed and opaque; supply unmasked
  layers, allow the system to apply platform corners, and keep the primary
  content centered. Prefer scalable foreground graphics.
- [Icon Composer](https://developer.apple.com/icon-composer/): background and
  foreground layers, controlled specular highlights, refraction, translucency,
  and default/dark/mono annotations. Its current official icon grid was visually
  inspected; it contains examples across Apple's platforms, not only iPhone.
- [WWDC26 Icon Composer lab](https://developer.apple.com/videos/play/wwdc2026/8012/):
  iOS 27 sharpens the rendering; Apple reduced translucency in many own icons to
  improve clarity. This is per-icon tuning, not a requirement to maximize glass.

## What was wrong with the implementation

The generated studies baked a rounded enclosure, material highlights, bevels,
and shadows into a single transparent PNG. Rescaling that whole PNG controlled
its enclosure footprint, but did not establish a current layered iOS design.
It conflated the source canvas, the system enclosure, and foreground geometry.

The photographic ceramic/glass treatment was also a stylistic interpretation,
not evidence of matching Apple's current system material.

## Correct production workflow to explore

1. Draw the original symbol as simple separate foreground shapes with a clear
   silhouette. Place it using the current official grid and optical judgment;
   do not reuse 80% as an arbitrary symbol-size constraint.
2. Use a full-canvas opaque background. Do not import a pre-rounded tile or an
   outer transparent margin as a background layer.
3. Compose the layers in Icon Composer and evaluate system-drawn materials.
   Avoid pre-baking effects that duplicate the system's treatment.
4. Review normal, dark, and mono appearances and actual device/context sizes.
   Icon Composer is already bundled with this Mac's Xcode; no new tool purchase
   or account is needed. Installed tool rendering/version still needs checking
   before claiming a preview specifically represents iOS 27.
5. Keep legacy macOS icns export and layered icon artwork as separate production
   concerns. Do not replace the submitted Ora build during visual exploration.

The earlier PNGs remain unselected concepts. This note corrects the design
direction; it does not claim that a production .icon or iPhone build exists.
