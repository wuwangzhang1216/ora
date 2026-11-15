# Ora icon studies — round 2

These raster studies are not the latest layered iOS production direction.
See [`../ios-current-direction.md`](../ios-current-direction.md). The 80%
normalization below is a local legacy-Mac comparison, not an Apple iOS standard.

Three original raster concepts generated using the built-in image-generation
tool. Exact prompts and generation method are preserved in `prompts.json`.

- **A / Fold / 折译:** blue-purple folded enamel planes, an angular exchange.
- **B / Duet / 合声:** a warm ceramic pair of quotation-like organic forms.
- **C / Lens / 透镜:** a single glass optical lozenge on an ink-blue tile.

`concepts.png` compares the artwork and 64/32/16 px reductions. It is a designed
comparison sheet, not a screenshot of the Dock.

The owner reported oversized Dock tiles. The source artwork occupied 86–91% of its canvas, versus about 80% in the local Finder icon. `normalized/` now contains centered 1024 px assets with an approximately 80% opaque-tile span. All icns sizes, preview apps, and the concept sheet consume those normalized assets. See `size-correction.json` for before/after measurements and the native Dock retest.

`raw/` preserves the generated sources. `prepare.swift` creates standard icns
resolutions and isolated, clearly named AppKit preview bundles under ignored
`.preview/`; it also renders the comparison. `IconPreview.swift` is a small
local display app with no audio capture, networking, translation, or access to
Ora's settings/history. Each variant has a separate `dev.ora.iconstudy.*` ID.

Build the previews with:

```sh
zsh design/icon-refresh/v2/build-previews.sh
```

These are unselected design concepts, not production vector masters or Icon
Composer assets. Do not overwrite the installed Ora, the submitted 0.10.1 (15)
binary, website assets, or signing artifacts with these studies. Refine a chosen
silhouette and make compatible production assets before a release build.

All three isolated apps were launched and observed together in the actual macOS Dock. The owner authorized the built-in capture command; unaltered full-Dock and detail screenshots are saved in ignored `macos/Ora/.app-store/icon-study-v2/`. The preview apps were quit and other app visibility restored afterward. See `verification.json`. Private desktop screenshots remain outside the public repository.
