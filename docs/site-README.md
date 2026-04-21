# Ora landing page

`docs/index.html` is a single-file landing page for **ora.app** (or
whatever domain you point at it). No build step, no framework, no JS
dependencies — pure HTML + embedded CSS, designed to deploy anywhere
that can serve static files.

## Structure

- `index.html` — hero → features (6 pillars) → multilingual → how it works → say-it banner → CTA → footer.
- Assets it references (all already in this repo):
  - `screenshots/app-icon.png` — favicon + nav logo
  - `posters/hero-dark.jpg` — hero image
  - `posters/languages.jpg` — multilingual section
  - `posters/say-it.jpg` — full-bleed tagline banner

## Deploy: GitHub Pages

1. Repo → **Settings** → **Pages**
2. Source: **Deploy from a branch**
3. Branch: `main` — Folder: `/docs`
4. Save. First build lands at `https://wuwangzhang1216.github.io/ora/` in ~1 minute.

The `docs/` folder already contains `posters/` and `screenshots/`, so
image paths work out of the box.

## Deploy: Vercel / Netlify / Cloudflare Pages

Any static host works. Point build output / publish directory at `docs/`:

- **Vercel** — Framework: "Other", Output directory: `docs`
- **Netlify** — Publish directory: `docs`
- **Cloudflare Pages** — Build output directory: `docs`

## Custom domain

Once GitHub Pages (or your static host) is serving, add a `CNAME` record
in your DNS:

```
CNAME   @   wuwangzhang1216.github.io.
```

Then in Settings → Pages, set the custom domain (e.g. `ora.app`) and
check **Enforce HTTPS**.

## Editing

The HTML is one file (~470 lines including CSS). Everything lives in
`<style>` in the head. Top of the stylesheet has design tokens:

```css
:root {
  --teal:      #26B8D1;
  --deep-blue: #1A4CB8;
  --violet:    #8C57E0;
  ...
}
```

Each section is plainly named (`.hero`, `.features`, `.multilingual`,
`.pipeline`, `.say-it`, `.cta`, `footer`). Change copy inline; rebuild is
just reloading the browser — no tooling.

## Why single-file

- **Zero build step** — no npm, no bundler, nothing to break.
- **Cold-start TTFB** is one HTTP request plus four JPEGs.
- **Lighthouse-friendly** out of the box: system fonts, deferred
  backdrop-filter, no layout shift.
- **No JS framework surface area** to maintain when you bump tokens.
