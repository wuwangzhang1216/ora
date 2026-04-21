# Ora — Product Hunt Launch Kit

Everything needed to submit Ora to Product Hunt. Copy-paste ready.

---

## 0. Positioning  (read this first)

**The story we are telling:** a simultaneous interpreter — the kind you
see in glass booths at the UN, or booked for diplomatic summits and
boardrooms — is one of the most elite professions in the world. They
translate *while* the speaker is still talking, work in pairs because of
the cognitive load, and cost a fortune to hire.

Ora puts one on your Mac. Free.

That's the hook. Every piece of copy below leans into that metaphor
before it reaches for a technical feature. The features exist to
*justify* the metaphor (sub-second latency → real-time like a human
interpreter; on-device → it's *yours*, always present; free → breaks
the exclusivity of the profession) — not to replace it.

Tone: quietly confident, a touch aspirational, Apple-adjacent. Never
chest-thumping, never "AI-powered".

---

## 1. Core listing copy

### Product name
**Ora**

### Tagline  (≤60 chars)  — pick one

- **Your personal simultaneous interpreter, on your Mac.**  (53)  ⭐ recommended
- Your personal interpreter. On your Mac. Free.  (46)
- A simultaneous interpreter, right on your Mac.  (47)
- The UN has simultaneous interpreters. Now you do too.  (53)  — bold, playful
- Live captions for every conversation.  (38)  — safer, less poetic

### Description  (≤260 chars)

> Simultaneous interpreters used to be reserved for heads of state. Ora puts one on your Mac. Speak any language, see live translations stream into a floating caption card — entirely on Apple Silicon. No cloud. No account. Free forever.

*(≈237 chars — leaves room for a trailing emoji if you want one)*

---

## 2. Maker's first comment  (pinned)

Paste this as the first comment the instant the launch goes live. PH
pins the maker's comment and weighs early engagement heavily.

> 👋 Hey Product Hunt — I'm the maker of Ora.
>
> Simultaneous interpreters — the ones you see behind glass booths at the UN — are some of the most elite professionals in the world. They translate in real time *as* the speaker is still talking, often juggling three or four languages in a session. It's one of the highest cognitive-load jobs on earth, and one of the most expensive services you can hire.
>
> Ora puts one on your Mac. Free.
>
> Hit ⌘⇧T, start speaking, and translations stream into a floating caption card *as you talk* — usually before you've finished the sentence. It's not "transcribe, then translate" — it's a rolling, live interpreter that keeps pace with you.
>
> Everything runs on your Mac's Metal GPU via MLX. No cloud. No account. No subscription. After the first model download, the whole thing works on an airplane.
>
> Chinese ↔ English ↔ Japanese ↔ Korean ↔ Spanish ↔ French ↔ German and more. Swap source and target from the menu bar.
>
> Signed + notarized `.dmg`, macOS 15+ on Apple Silicon. There's also a Python reference implementation in the repo if you want to see the pipeline.
>
> I'll be in the comments all day. Really curious which conversations you'd bring Ora to — travel, meetings, family calls, conference talks. 🙏

---

## 3. Topics / categories

Pick **3 primary** + up to 2 secondary:

- **Productivity** ✅
- **Mac** ✅
- **Artificial Intelligence** ✅
- Language Learning
- Accessibility  *(live captions help deaf / HoH users too — worth mentioning)*
- Travel  *(lean into the "bring an interpreter everywhere" angle)*

---

## 4. Links

| Field | URL |
|------|-----|
| Website / download | https://github.com/wuwangzhang1216/ora/releases/latest |
| Source / CLI reference | https://github.com/wuwangzhang1216/ora |
| Latest release | https://github.com/wuwangzhang1216/ora/releases/tag/v0.3.0 |
| Maker | https://github.com/wuwangzhang1216 |

Pricing: **Free**. No paid tier. No in-app purchases.

---

## 5. Assets

All assets live in [docs/posters/](posters/) and [docs/screenshots/](screenshots/).

### Thumbnail  (required — 240×240 min)
- **[docs/posters/square.jpg](posters/square.jpg)**  (2160 × 2160, downscale on upload)

The first gallery image is also used as the social meta image when the
PH link is shared. It must read cleanly cropped to 1.91:1 (OpenGraph)
and 1:1 (Twitter card).

### Gallery  (upload in this order — tells the story)

Product Hunt spec: **1270 × 760 px**. All of these are 2× (2540 × 1520)
and will downsample cleanly.

| # | File | Role | Headline on image |
|---|------|------|-------------------|
| 1 | [hero-dark.jpg](posters/hero-dark.jpg) | Primary hero — product at a glance | *(mockup + 5 benefit pills)* |
| 2 | [say-it.jpg](posters/say-it.jpg) | Emotional hook | **Say it. See it translated.** |
| 3 | [instant.jpg](posters/instant.jpg) | Real-time / simultaneous | **At the speed of speech.** |
| 4 | [languages.jpg](posters/languages.jpg) | Multilingual — the whole point of an interpreter | **Every language.** |
| 5 | [local.jpg](posters/local.jpg) | On-device | **Runs on your Mac.** |
| 6 | [private.jpg](posters/private.jpg) | Privacy | **Never leaves your Mac.** |
| 7 | [offline.jpg](posters/offline.jpg) | Offline | **No internet. No problem.** |
| 8 | [free.jpg](posters/free.jpg) | Pricing close | **Free. Forever.** |

Extras on standby:
- [hero-light.jpg](posters/hero-light.jpg) — light-mode variant of the hero.
- [accurate.jpg](posters/accurate.jpg) — two-mockup demo of idiomatic translation quality; swap in if a commenter asks "how good is the translation?"
- [docs/screenshots/caption-window.png](screenshots/caption-window.png) — real app screenshot, useful in deep-dive replies.

---

## 6. Social launch copy

Post these at **12:01 AM PT** the day of launch — that's when the PH
day begins and early upvotes carry the most weight. Lead everywhere
with the interpreter framing; features follow.

### X / Twitter — launch tweet  (hero-dark.jpg attached)

> Simultaneous interpreters used to be reserved for heads of state.
>
> Today I'm putting one on your Mac. Free.
>
> Ora is live on @ProductHunt — real-time speech translation that streams into a floating caption card *as you speak*. No cloud. No account. Ever.
>
> 🙏 {PRODUCT_HUNT_LINK}

### X / Twitter — follow-up thread  (reply chain to the launch tweet)

> 2/ A UN interpreter translates *while* the speaker is still talking. Not "record, then translate." A human brain running two languages in parallel, at the edge of real-time.
>
> Ora does the same. Rolling partials stream into the caption card every ~600 ms. By the time you pause, it's already committed the sentence.
>
> 3/ Everything runs on your Mac's Metal GPU via MLX. Audio never leaves the device. No subscription, no API keys, no "sorry, you've hit your monthly quota."
>
> The one and only network call is the first-time model download.
>
> 4/ Chinese ↔ English ↔ Japanese ↔ Korean ↔ Spanish ↔ French ↔ German and more, in both directions. Flip source and target from the menu bar.
>
> 5/ Signed + notarized .dmg, macOS 15+ on Apple Silicon. Python reference implementation is open-source if you want to inspect the pipeline.
>
> Download → {GITHUB_RELEASE_LINK}
> Upvote → {PRODUCT_HUNT_LINK}

### LinkedIn  (more professional, hero-dark.jpg attached)

> Simultaneous interpreters — the people you see in glass booths at the UN — are some of the most elite professionals in the world. They translate in real time, work in pairs because of the cognitive load, and cost a fortune to hire for a single day.
>
> I built Ora to put one on your Mac. Free forever.
>
> Ora is a menu-bar app that listens to your microphone, runs on-device speech recognition and translation via MLX on your Apple Silicon's Metal GPU, and streams captions into a floating window in under a second — usually before you've finished the sentence.
>
> Audio never leaves your device. No cloud, no account, no subscription. After the first model download, airplane mode works indefinitely.
>
> Launching on Product Hunt today. If this resonates, an upvote goes a long way.
>
> → {PRODUCT_HUNT_LINK}

### Reddit  (r/macapps, r/MacOS, r/LocalLLaMA)

**Title:** `Ora — a simultaneous interpreter on your Mac (free, offline, on-device)`

**Body:**

> I wanted a real simultaneous interpreter on my Mac — the kind that translates *while* you're talking, not a batch "transcribe then translate" flow. And I wanted it fully on-device, no cloud, no API keys.
>
> Ora hit v0.3 today. Hit ⌘⇧T, start speaking, and captions stream into a floating window in under a second. Chinese ↔ English ↔ Japanese ↔ Korean ↔ Spanish ↔ French ↔ German and more.
>
> Free forever, signed + notarized DMG, macOS 15+ on Apple Silicon. There's also a Python reference implementation in the repo if you want to look under the hood.
>
> Launching on Product Hunt today, upvote if it's useful:
> {PRODUCT_HUNT_LINK}
>
> Happy to answer anything about the architecture, latency tuning, on-device model choices.

### Hacker News  (Show HN — keep it factual, HN hates hype)

**Title:** `Show HN: Ora – on-device simultaneous interpreter for Mac (MLX, offline)`

**First comment:**

> Maker here. Ora is a menu-bar app that does real-time speech translation fully on-device. Pipeline is Silero VAD → on-device ASR → on-device translator LLM, all running on Apple Silicon's Metal GPU via MLX.
>
> The design goal was to match the cadence of a human simultaneous interpreter: translate *while* the speaker is still talking, rather than batch-transcribe-then-translate. Rolling-partial transcription gives sub-second perceived latency; the full end-of-speech commit lands ~500 ms after silence is detected.
>
> macOS 15+ on Apple Silicon only (MLX). Free, signed, notarized. Happy to go deep on any of the tech choices — model selection, VAD hysteresis, streaming LLM prompting, etc.

---

## 7. Pre-launch checklist  (T-48h → T-0)

- [ ] **T-48h** — Confirm `v0.3.0` DMG on [Releases](https://github.com/wuwangzhang1216/ora/releases) is notarized and downloads cleanly on a fresh machine.
- [ ] **T-48h** — README updated and landing-friendly (it is — `fd187dc`).
- [ ] **T-24h** — Final review of all 11 posters. Thumbnail is the square. First image is `hero-dark.jpg`.
- [ ] **T-24h** — Draft the PH listing as a **scheduled** launch for 12:01 AM PT (Pacific). Don't submit immediately — scheduling guarantees the full-day window.
- [ ] **T-24h** — Line up the hunter (optional but helps); share the scheduled link privately.
- [ ] **T-12h** — Queue the launch tweet, LinkedIn post, subreddit post, Show HN as drafts. Do **not** post yet.
- [ ] **T-0** (12:01 AM PT) — PH launches automatically. Publish tweet, LinkedIn, Reddit, HN in that order within 10 minutes.
- [ ] **T+0 → T+1h** — Pin the maker's first comment on PH. Reply to every early comment in ≤10 min.
- [ ] **T+1h → T+12h** — Check replies hourly. Engage in HN thread. Update README if rank becomes brag-worthy.
- [ ] **T+12h → T+24h** — Post a mid-day thank-you reply on PH summarizing the top questions so far.
- [ ] **T+24h** — Post a "thanks everyone" recap tweet with the final rank + top user quotes (with permission).

---

## 8. FAQ pre-writes  (stock answers for PH / HN comments)

**"Calling it 'UN-grade' isn't that a stretch?"**
> Fair challenge. The *cadence* is real — streaming partials with sub-second latency is how human simultaneous interpreters work. The *quality* of course depends on the specific language pair and topic. The metaphor is about the mode (live, rolling), not the equivalence of training data to a career professional.

**"Does it work for meetings / calls / YouTube videos?"**
> Yes — the latest version has a System Audio source, so any app your Mac plays can be routed through the translator. Preferences → Audio Input → System Audio. First use prompts for Screen Recording permission.

**"How big are the models?"**
> ~1.2 GB for Standard (default), ~3 GB for High, ~6 GB for Extra High. Downloaded on first use, stored in `~/Documents/huggingface/`. You only pull a tier when you actually switch to it.

**"Is it really fully offline?"**
> Yes — the only network traffic is the initial Hugging Face model download. After that, airplane mode works indefinitely. Verify with Little Snitch if you like.

**"Why only Apple Silicon?"**
> MLX (the inference framework) targets Metal on M-series chips. Intel Macs don't have the GPU architecture this pipeline depends on. Not on the roadmap.

**"Does it work on iOS?"**
> There's an iOS companion in the repo that uses Apple's native Translation framework for translation + Qwen3-ASR on MLX for speech. Different pipeline, same product surface. Not yet released publicly.

**"What about privacy?"**
> No audio ever touches the network. No telemetry, no crash reports, no analytics. After the one-time model download, there is zero outbound traffic.

**"Is it open source?"**
> The macOS app is closed source — only the notarized DMG ships. The Python reference implementation in [`main.py`](../main.py) is open-source and reproduces the same pipeline with open dependencies (Silero VAD + MLX-Local-Serving + Ollama) so the architecture is fully inspectable.

**"Can I contribute a language?"**
> The app uses on-device LLMs which already speak dozens of languages; if a pair underperforms, open an issue with the source / expected translation and I'll look at whether a prompt or target-language adjustment fixes it.

---

## 9. Afterwards  (post-launch housekeeping)

- Pin the PH link in the repo's README (top badge row).
- Add a "Featured on Product Hunt" badge near the top of README once the launch day ends.
- Capture the top 3 PH comments as testimonial quotes for v0.4 marketing.
- Archive this file with the final rank / comment count / link for the next launch's reference.
