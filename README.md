# 🎤 Local Real-Time Translator

Pure-local real-time speech translation. No cloud. No API keys. Everything on-device.

```
Mic → Silero VAD → Qwen3-ASR-1.7B (mls, MLX) → Qwen3.5-4B (Ollama) → Terminal
```

## Requirements

- macOS with Apple Silicon (M1+)
- Python 3.10+
- ~8GB disk (Qwen3-ASR-1.7B-8bit + Qwen3.5-4B Q4)
- 16GB+ unified memory recommended

## Quick Start

```bash
# One-shot install (Homebrew, Ollama, mls, Python deps, model weights)
./setup.sh

# Run — launches mls + Ollama in the background if not already up
./run.sh

# Pass any CLI flag straight through to main.py
./run.sh --asr-lang ja --target English
```

`run.sh` only stops the services it started itself, so it's safe to run alongside an
Ollama or `mls` instance you're already using.

## Usage

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

## Why this stack

| Component | Choice | Why |
|-----------|--------|-----|
| **VAD** | Silero VAD | Deep-learning VAD, ~4× fewer errors than WebRTC VAD at the same FPR; RTF 0.004 on CPU |
| **ASR** | Qwen3-ASR-1.7B (8-bit MLX) via `mls` | Beats Whisper-large-v3 on most benchmarks (AISHELL-2: 2.71 vs 5.06 WER); runs on Metal GPU |
| **LLM** | Qwen3.5-4B via Ollama | Strong multilingual translation, ~3GB VRAM, streams tokens |
| **Transport** | HTTP to `mls` + Ollama | Two independent local servers, easy to restart/debug |

## Architecture

```
┌─────────────┐   ┌───────────┐   ┌──────────────────┐   ┌───────────────┐
│  Microphone  │──▶│ Silero VAD│──▶│  mls (Qwen3-ASR) │──▶│ Ollama (LLM)  │
│  sounddevice │   │ endpoint  │   │  MLX, Metal GPU  │   │  qwen3.5:4b   │
│  16kHz mono  │   │ detection │   │  text out        │   │  stream tokens │
└─────────────┘   └───────────┘   └──────────────────┘   └───────────────┘
      │                │                   │                     │
      │         ~10ms/frame         ~200-400ms/utt         ~300-600ms/utt
      │                │                   │                     │
      └── VAD-gated utterances ──────────────────────────▶ Terminal
```

**End-to-end latency**: ~800ms–1s after you stop speaking (VAD end-of-speech 300ms + ASR ~300ms + first LLM token ~200ms). Rolling partials appear *while* you're still speaking, so the perceived latency is lower still.

## Live partials

While you're speaking, a background worker re-runs ASR + a non-streaming translate on the growing audio buffer every ~0.8s (only if the buffer has grown by ≥0.3s) and redraws a yellow `⟳` line in place. When you stop, the partial line is cleared and the final streamed translation is printed. Stale partials are dropped whenever newer audio arrives, so you never see out-of-order output.

## Tuning

- **Latency vs false-cut**: `SPEECH_END_MS` in `main.py` (default 300) — raise it for slower/pausing speakers, lower it for snappier end-of-turn
- **Partial cadence**: `PARTIAL_INTERVAL_S` (default 0.8s) and `PARTIAL_MIN_GROWTH_S` (default 0.3s) control how often in-flight partials are re-transcribed
- **VAD sensitivity**: `--vad-threshold` 0.3 = lenient, 0.7 = strict
- **Translation quality**: `--ollama-model qwen3.5:9b` for better nuance at higher latency
- **Source language hint**: `--asr-lang zh` skips auto-detect and can improve accuracy on short utterances

## License

MIT
