<p align="center">
  <img src="docs/screenshots/app-icon.png" width="160" alt="Ora app icon"/>
</p>

<h1 align="center">Ora</h1>

<p align="center">
  <strong>Real-time local speech translation for macOS.</strong><br/>
  Everything runs on your Mac — no cloud, no API keys, no data ever leaves the device.
</p>

<p align="center">
  <a href="https://github.com/wuwangzhang1216/ora/releases/latest">
    <img src="https://img.shields.io/github/v/release/wuwangzhang1216/ora?label=download&color=0a78be" alt="Latest release"/>
  </a>
  <img src="https://img.shields.io/badge/macOS-15%2B-0a78be" alt="macOS 15+"/>
  <img src="https://img.shields.io/badge/Apple%20Silicon-required-0a78be" alt="Apple Silicon"/>
  <img src="https://img.shields.io/badge/license-MIT-0a78be" alt="MIT"/>
</p>

---

## What is Ora?

Ora listens to your microphone and streams live translations of what you say into a floating caption window, using on-device MLX models for both speech recognition and translation. It's designed as a small, focused menu-bar app — click once, talk, read.

- 🎙 **Native real-time**: Silero VAD → Qwen3-ASR-1.7B → Qwen3.5-2B/4B LLM, all on Metal
- 🔒 **100% local**: no network calls after the one-time model download, no API keys, no telemetry
- ⚡️ **Low latency**: sub-second caption updates while you're still speaking, ~600 ms end-of-speech commit
- 🪟 **Minimal UI**: menu bar icon + a single floating caption card, keyboard-shortcut driven
- 🌍 **Multilingual**: translate between Chinese, English, Japanese, Korean, French, German, Spanish, and more
- 🎚 **Tunable**: preferences for target language, quality tier, VAD sensitivity, end-of-speech window

## Screenshots

<p align="center">
  <img src="docs/screenshots/caption-window.png" width="640" alt="Live caption window with Chinese source and English translation"/>
  <br/>
  <em>Floating caption card — source text above, large translation below, live status indicator + target-language chip.</em>
</p>

<p align="center">
  <img src="docs/screenshots/preferences.png" width="420" alt="Preferences window"/>
  <br/>
  <em>Preferences — target language, quality tier, ASR source hint, VAD sensitivity + end-of-speech window, hotkey.</em>
</p>

## Download

Grab the signed and notarized `Ora.dmg` from the [latest release](https://github.com/wuwangzhang1216/ora/releases/latest), double-click to mount, drag **Ora.app** to **Applications**, launch.

- Requires **macOS 15 (Sequoia) or later** and an **Apple Silicon** Mac (M1/M2/M3/M4)
- ~1.2 GB model download on first launch (the 2B translator + ASR + VAD)
- First launch prompts for microphone access — required for speech capture

## Usage

1. Click the echo-ring icon in the menu bar.
2. Choose **Start Listening** (or press ⌘⇧T from anywhere).
3. Speak. The floating caption window appears automatically.
4. Hover the caption window to reveal ⏸ / ⧉ / ✕ controls (pause, copy translation, hide).
5. Press ⌘, for Preferences — change target language, quality tier, VAD sensitivity.

### Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘⇧T | Start / stop listening (global) |
| ⌘⇧H | Show / hide caption window |
| ⌘, | Preferences |
| ⌘Q | Quit Ora |

### Quality tiers

| Tier | Model | Download | Latency | Best for |
|------|-------|----------|---------|----------|
| **Standard** (default) | Qwen3.5-2B-MLX-4bit | ~1.2 GB | ~400-700 ms/utterance | Casual conversation, news, video |
| **High** | Qwen3.5-4B-MLX-4bit | ~3 GB | ~600-1100 ms/utterance | Nuanced content, technical terms |

Switch at any time from the menu bar → **Quality**. The new model downloads automatically on first use.

## Architecture

```
┌──────────┐    ┌───────────┐    ┌──────────────┐    ┌────────────────┐
│  Mic     │───▶│ Silero VAD│───▶│  Qwen3-ASR   │───▶│ Qwen3.5 LLM    │
│ 16 kHz   │    │ hysteresis│    │  1.7B MLX    │    │ 2B or 4B MLX   │
│ Float32  │    │ frame VAD │    │  Metal GPU   │    │  Metal GPU     │
└──────────┘    └───────────┘    └──────────────┘    └────────────────┘
     │                │                  │                   │
     │          ~30 ms/frame       ~300-500 ms         ~300-700 ms
     │                │                  │                   │
     └── AVAudioEngine ──────────────────────▶ SwiftUI Caption Card
```

- **VAD**: frame-level Silero with start/stop hysteresis (0.5 / 0.35) — industry-standard endpointing
- **ASR**: batch Qwen3-ASR-1.7B re-invoked on a growing buffer every ~600 ms (sliding-window partial transcription)
- **LLM**: `mlx-swift-lm` ChatSession streaming tokens straight to the SwiftUI caption card, thinking mode off
- **UI**: SwiftUI `MenuBarExtra` + borderless `NSPanel` with `NSHostingController` auto-resize and persisted window origin

All four stages run on the Metal GPU via [MLX Swift](https://github.com/ml-explore/mlx-swift) — no Python, no Ollama, no external server.

> The Swift source for the Ora macOS app is closed source. Only the signed,
> notarized `Ora.dmg` is published in [GitHub Releases](https://github.com/wuwangzhang1216/ora/releases). If you want to inspect or modify the pipeline, the Python reference implementation below reproduces the same architecture with open dependencies (Silero VAD + `mls` ASR server + Ollama).

## Python CLI (open-source reference implementation)

<p align="center">
  <img src="docs/screenshots/cli.png" width="720" alt="Python CLI running in terminal with live VAD meter"/>
  <br/>
  <em>Live rich-terminal UI — status bar, per-utterance source + translation, scrolling history, and a real-time VAD probability meter.</em>
</p>

A Python implementation lives in [`main.py`](main.py) — the same architecture as the Ora macOS app, built on top of `mls` (an MLX model serving daemon) for ASR and Ollama for translation. It's useful for:

- Running on macOS versions that don't meet the Ora app's 15.0 requirement
- Reading / forking a fully open-source implementation of the same pipeline
- Iterating on prompts or VAD settings without rebuilding anything
- Watching a live VAD-level meter in a rich terminal UI

The CLI uses the same industry-standard VAD config as the Ora app (hysteresis 0.5 / 0.35, end-of-speech 500 ms, partial cadence 600 ms).

```bash
# One-shot install (creates .venv, pulls Ollama models, clones mls, preloads weights)
./setup.sh

# Start Ollama + mls + run translator CLI
./run.sh --target English --asr-lang zh
```

See [setup.sh](setup.sh) and [run.sh](run.sh) for the full dependency chain.

## Privacy

Ora doesn't phone home. The only network traffic is the initial HuggingFace model download, after which the app runs fully offline. No telemetry, no crash reporting, no analytics. Microphone audio never leaves your machine.

## License

MIT.
