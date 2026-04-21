# Ora promo posters

Rendered by [`generate-posters.swift`](generate-posters.swift).

**Design direction** — Apple product-page minimalism with one clear
benefit per page (the Product Hunt gallery pattern: "show, don't tell,
one feature per image, heading < 10 words, visuals carry the message").

- Teal → deep-blue brand gradient (same as AppIcon).
- Faked glassmorphism — atmospheric colored radial blobs behind
  semi-transparent rounded cards with soft drop shadows, top highlight
  and thin 1 px border.
- SF Pro Display typography, kerned.
- Each benefit page uses a distinctive layout + an SF Symbol accent so
  the 10-image set reads as a cohesive gallery, not ten identical slides.

## The gallery

| File | Purpose | Headline |
|------|---------|----------|
| [hero-dark.jpg](hero-dark.jpg) | PH slot 1 — primary hero (dark) | *Product mockup + 5 benefit pills* |
| [hero-light.jpg](hero-light.jpg) | Light variant of the hero | *Same, light scheme* |
| [local.jpg](local.jpg) | Pillar — on-device | **Runs on your Mac.** — Apple Silicon · Metal GPU accent |
| [instant.jpg](instant.jpg) | Pillar — real-time latency | **At the speed of speech.** — bolt glyph + live-partial demo |
| [offline.jpg](offline.jpg) | Pillar — works offline | **No internet. No problem.** — wifi-slash glyph |
| [private.jpg](private.jpg) | Pillar — privacy | **Never leaves your Mac.** — lock-shield accent |
| [accurate.jpg](accurate.jpg) | Pillar — translation quality | **Word for word.** — two mockups with idiomatic translations |
| [free.jpg](free.jpg) | Pillar — pricing | **Free. Forever.** — pure typography, mint glow |
| [languages.jpg](languages.jpg) | Pillar — multilingual | **Every language.** — three mockups, three language pairs |
| [say-it.jpg](say-it.jpg) | Emotional tagline | **Say it. See it translated.** — split, tilted mockup |
| [square.jpg](square.jpg) | Thumbnail / social 1:1 | *Mockup + wordmark* |

All landscape posters are **2540 × 1520** (2× of PH's 1270 × 760). The
square is **2160 × 2160** for a sharp 1:1 thumbnail.

## Regenerate

```bash
swift docs/posters/generate-posters.swift
```

No external dependencies — AppKit + CoreGraphics only. Requires macOS
with Xcode command-line tools. SF Symbol glyphs use the system library.

## Editing

Primitives at the top of the script:

- **Brand tokens** — `brandTeal`, `brandDeepBlue`, `brandViolet`, `brandWarm`.
- **Typography** — `font(size, weight:)`, `textSize`, `drawText`, `drawCenteredTextAtTop`, `drawWrappedText`.
- **Glass card** — `drawGlassCard(rect, cornerRadius:, scheme:)` paints the shadowed + tinted + top-highlighted + bordered pane.
- **Caption mockup** — `drawCaptionMockup(rect, scheme:, sourceText:, translationText:, targetLang:)` and `drawMiniCaptionMockup` for compact variants.
- **SF Symbol** — `drawSymbol(name:, center:, pointSize:, color:, glow:)` draws any SF Symbol tinted and optionally glowing.
- **Atmosphere** — `drawAtmosphericBackdrop(size, scheme:)` paints the dark/light canvas with soft color blobs.

Each poster is a `renderXxx()` function that composes those primitives.
Tweak copy or layout in-place, then rerun the script.
