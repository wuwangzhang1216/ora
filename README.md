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

**End-to-end latency**: ~1.5–2s after you stop speaking (VAD end-of-speech 600ms + ASR ~300ms + first LLM token ~200ms).

## Tuning

- **Latency vs false-cut**: lower `SPEECH_END_MS` in `main.py` (default 600) for snappier end-of-turn, higher for slower/pausing speakers
- **VAD sensitivity**: `--vad-threshold` 0.3 = lenient, 0.7 = strict
- **Translation quality**: `--ollama-model qwen3.5:9b` for better nuance at higher latency
- **Source language hint**: `--asr-lang zh` skips auto-detect and can improve accuracy on short utterances

## License

MIT
