<div align="center">

# 🎤 Local Real-Time Translator

**Pure on-device real-time speech translation for Apple Silicon.**
No cloud. No API keys. No telemetry.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Apple%20Silicon-blue.svg)](#requirements)
[![Python](https://img.shields.io/badge/python-3.12-blue.svg)](https://www.python.org/)
[![MLX](https://img.shields.io/badge/MLX-Metal%20GPU-orange.svg)](https://github.com/ml-explore/mlx)
[![Ollama](https://img.shields.io/badge/Ollama-qwen3.5%3A4b-black.svg)](https://ollama.com/)

`Mic → Silero VAD → Qwen3-ASR-1.7B (MLX) → Qwen3.5-4B (Ollama) → Terminal`

</div>

---

## ✨ Preview

<div align="center">

![Screenshot](screenshot.png)

*Live partials stream in as you speak; finalized translations settle below.*

</div>

## 🚀 Highlights

- **100% local.** Audio never leaves your machine. No vendor lock-in, no API bills, works offline.
- **Low latency.** ~800ms–1s from end-of-speech to first translated token. Rolling partials cut the *perceived* latency even lower.
- **Metal-accelerated ASR.** Qwen3-ASR-1.7B runs 8-bit on the Apple GPU via MLX — beats Whisper-large-v3 on most benchmarks.
- **Swap-friendly.** Point `--ollama-model` at any local LLM; `--asr-lang` / `--target` let you pivot source/target at the CLI.
- **Rich TUI.** Live status panel, streaming tokens, colorized transcript history.

## 📦 Requirements

| | |
|---|---|
| **OS** | macOS 13+ on Apple Silicon (M1/M2/M3/M4) |
| **Python** | 3.12 (installed automatically via `uv`) |
| **Disk** | ~8 GB (Qwen3-ASR-1.7B-8bit + Qwen3.5-4B Q4) |
| **RAM** | 16 GB unified memory recommended |
| **Mic** | Any CoreAudio input device |

## ⚡ Quick Start

```bash
# 1. One-shot install — Homebrew, Ollama, mls, Python deps, model weights
./setup.sh

# 2. Run — launches mls + Ollama in the background if not already up
./run.sh

# 3. Pass any CLI flag straight through to main.py
./run.sh --asr-lang ja --target English
```

> `run.sh` only stops the services it started itself, so it's safe to run alongside an Ollama or `mls` instance you're already using.

## 🎛️ Usage

```bash
# Auto-detect source → Chinese (default)
python main.py

# Japanese → English with explicit ASR hint
python main.py --asr-lang ja --target English

# Swap the translator LLM
python main.py --ollama-model qwen3.5:9b

# Stricter VAD for noisy rooms
python main.py --vad-threshold 0.7
```

### CLI flags

| Flag | Default | Description |
|---|---|---|
| `--target` | `Chinese` | Target language (free-form; passed to the LLM prompt) |
| `--asr-lang` | *auto* | Source-language hint (`zh`, `en`, `ja`, …) |
| `--ollama-model` | `qwen3.5:4b` | Any Ollama model tag installed locally |
| `--ollama-url` | `http://localhost:11434` | Ollama API endpoint |
| `--mls-url` | `http://127.0.0.1:18321` | `mls` ASR server endpoint |
| `--vad-threshold` | `0.5` | Silero speech probability cutoff (0.3 lenient → 0.7 strict) |

## 🧠 Why this stack

| Component | Choice | Why |
|---|---|---|
| **VAD** | Silero VAD | Deep-learning VAD, ~4× fewer errors than WebRTC VAD at the same FPR; RTF 0.004 on CPU |
| **ASR** | Qwen3-ASR-1.7B (8-bit MLX) via `mls` | Beats Whisper-large-v3 on most benchmarks (AISHELL-2: 2.71 vs 5.06 WER); runs on the Metal GPU |
| **LLM** | Qwen3.5-4B via Ollama | Strong multilingual translation, ~3 GB VRAM, streams tokens |
| **Transport** | HTTP to `mls` + Ollama | Two independent local servers, trivial to restart/debug |

## 🏗️ Architecture

```
┌─────────────┐   ┌───────────┐   ┌──────────────────┐   ┌───────────────┐
│ Microphone  │──▶│ Silero VAD│──▶│  mls (Qwen3-ASR) │──▶│ Ollama (LLM)  │
│ sounddevice │   │ endpoint  │   │  MLX, Metal GPU  │   │  qwen3.5:4b   │
│ 16kHz mono  │   │ detection │   │  text out        │   │ stream tokens │
└─────────────┘   └───────────┘   └──────────────────┘   └───────────────┘
      │                │                   │                     │
      │         ~10ms/frame         ~200–400ms/utt         ~300–600ms/utt
      │                │                   │                     │
      └── VAD-gated utterances ────────────────────────────▶ Terminal (rich)
```

**End-to-end latency:** ~800ms–1s after you stop speaking (VAD end-of-speech 300ms + ASR ~300ms + first LLM token ~200ms). Rolling partials appear *while* you're still speaking, so the perceived latency is lower still.

### Live partials

While you're speaking, a background worker re-runs ASR + a non-streaming translate on the growing audio buffer every ~0.8s (only if the buffer has grown by ≥0.3s) and redraws an in-place partial line. When you stop, the partial is cleared and the final streamed translation is printed. Stale partials are dropped whenever newer audio arrives, so you never see out-of-order output.

## 🎚️ Tuning

| Knob | Where | Effect |
|---|---|---|
| `SPEECH_END_MS` | [main.py](main.py) (default `300`) | Trailing-silence before an utterance is finalized. ↑ for slower/pausing speakers, ↓ for snappier end-of-turn |
| `PARTIAL_INTERVAL_S` | [main.py](main.py) (default `0.8`) | How often in-flight partials are re-transcribed |
| `PARTIAL_MIN_GROWTH_S` | [main.py](main.py) (default `0.3`) | Skip a partial if the buffer didn't grow by at least this much |
| `--vad-threshold` | CLI (default `0.5`) | `0.3` = lenient (catches whispers), `0.7` = strict (better for noisy rooms) |
| `--ollama-model` | CLI | Swap in a bigger model (`qwen3.5:9b`) for better nuance at higher latency |
| `--asr-lang` | CLI | Skip auto-detect — improves accuracy on short utterances |

## 🧩 Troubleshooting

<details>
<summary><b><code>mls</code> server won't start</b></summary>

`mls` has an incomplete `requirements.txt`; [setup.sh](setup.sh) installs the missing `mlx-vlm` and `python-multipart` automatically. If you installed `mls` manually, add them yourself.
</details>

<details>
<summary><b>Ollama model not found</b></summary>

Run `ollama pull qwen3.5:4b` (or whatever `--ollama-model` you're using). [setup.sh](setup.sh) does this for you on first run.
</details>

<details>
<summary><b>No microphone input / silent</b></summary>

Grant the terminal app microphone permission in *System Settings → Privacy & Security → Microphone*. `sounddevice` surfaces CoreAudio errors to stderr — watch for `[audio]` lines.
</details>

## 📄 License

[MIT](LICENSE)
