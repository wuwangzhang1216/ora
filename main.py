#!/usr/bin/env python3
"""
Pure-local real-time translator
Silero VAD + Qwen3-ASR-1.7B (via mls) + Qwen3.5-4B (via Ollama)

Architecture:
  Mic → sounddevice (16kHz PCM) → Silero VAD → utterance
      → mls HTTP (Qwen3-ASR-1.7B-8bit, MLX) → text
      → Ollama HTTP (qwen3.5:4b, streaming) → translated text → terminal

No network calls. No API keys. Everything on-device (Metal GPU via MLX + Ollama).
"""

import argparse
import json
import os
import queue
import sys
import tempfile
import threading
import time
from collections import deque

import numpy as np
import requests
import sounddevice as sd
import soundfile as sf
import torch
from silero_vad import load_silero_vad

# ──────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────

DEFAULT_OLLAMA_MODEL = "qwen3.5:4b"
DEFAULT_OLLAMA_URL = "http://localhost:11434"
DEFAULT_MLS_URL = "http://127.0.0.1:18321"
SAMPLE_RATE = 16000
VAD_FRAME_SAMPLES = 512           # Silero requires exactly 512 samples @ 16kHz (~32ms)
VAD_FRAME_MS = VAD_FRAME_SAMPLES * 1000 // SAMPLE_RATE
VAD_THRESHOLD = 0.5               # speech probability cutoff
SPEECH_START_FRAMES = 3           # ~96ms of voiced frames to trigger start
SPEECH_END_MS = 300               # trailing silence to end an utterance (tight for low latency)
PRE_ROLL_MS = 200                 # audio kept before speech start
MIN_UTTERANCE_MS = 300            # drop anything shorter
MAX_UTTERANCE_S = 15              # safety cap for run-on speech
PARTIAL_INTERVAL_S = 0.8          # emit a rolling partial every N seconds during speech
PARTIAL_MIN_GROWTH_S = 0.3        # only re-ASR if buffer grew by this much
OLLAMA_KEEP_ALIVE = "24h"         # keep LLM resident
TRANSLATE_SYSTEM_PROMPT = """\
You are a real-time speech translator. Translate the user's text into {target_lang}.
Rules:
- Output ONLY the translation. No explanations, no quotes, no markdown.
- Preserve the original tone and register.
- If the input is already in {target_lang}, output it unchanged.
- Translate even short fragments, hesitations ("uh", "嗯"), and incomplete sentences literally.
- Never output an empty response; if truly nothing to translate, echo the input.\
"""


# ──────────────────────────────────────────────
# Audio capture
# ──────────────────────────────────────────────

class VADSegmenter:
    """Mic capture with Silero VAD endpointing. Yields one utterance per speech span."""

    def __init__(
        self,
        sample_rate: int = SAMPLE_RATE,
        threshold: float = VAD_THRESHOLD,
    ):
        self.sample_rate = sample_rate
        self.threshold = threshold
        print("[vad] Loading Silero VAD...")
        self.model = load_silero_vad()
        print("[vad] Ready.")
        self.q: queue.Queue[np.ndarray] = queue.Queue()

    def _callback(self, indata, frames, time_info, status):
        if status:
            print(f"[audio] {status}", file=sys.stderr)
        self.q.put(indata[:, 0].copy())

    def _frames(self):
        """Yield fixed-size float32 frames (VAD_FRAME_SAMPLES) from the mic queue."""
        buf = np.zeros(0, dtype=np.float32)
        while True:
            data = self.q.get()
            buf = np.concatenate([buf, data])
            while len(buf) >= VAD_FRAME_SAMPLES:
                yield buf[:VAD_FRAME_SAMPLES].copy()
                buf = buf[VAD_FRAME_SAMPLES:]

    def _is_speech(self, frame: np.ndarray) -> bool:
        with torch.no_grad():
            prob = self.model(torch.from_numpy(frame), self.sample_rate).item()
        return prob >= self.threshold

    def events(self):
        """Yield ('partial', audio) during speech and ('final', audio) at end-of-speech."""
        pre_roll_frames = max(1, PRE_ROLL_MS // VAD_FRAME_MS)
        end_silence_frames = max(1, SPEECH_END_MS // VAD_FRAME_MS)
        min_frames = max(1, MIN_UTTERANCE_MS // VAD_FRAME_MS)
        max_frames = int(MAX_UTTERANCE_S * 1000 / VAD_FRAME_MS)
        partial_growth_frames = max(1, int(PARTIAL_MIN_GROWTH_S * 1000 / VAD_FRAME_MS))

        pre_roll: deque[np.ndarray] = deque(maxlen=pre_roll_frames)
        voiced: list[np.ndarray] = []
        triggered = False
        voiced_run = 0
        silence_run = 0
        last_partial_ts = 0.0
        last_partial_frames = 0

        with sd.InputStream(
            samplerate=self.sample_rate,
            channels=1,
            dtype="float32",
            blocksize=VAD_FRAME_SAMPLES,
            callback=self._callback,
        ):
            print("[mic] Listening... (Ctrl+C to stop)\n")
            for frame in self._frames():
                is_speech = self._is_speech(frame)

                if not triggered:
                    pre_roll.append(frame)
                    if is_speech:
                        voiced_run += 1
                        if voiced_run >= SPEECH_START_FRAMES:
                            triggered = True
                            voiced.extend(pre_roll)
                            pre_roll.clear()
                            silence_run = 0
                            last_partial_ts = time.monotonic()
                            last_partial_frames = len(voiced)
                    else:
                        voiced_run = 0
                else:
                    voiced.append(frame)
                    if is_speech:
                        silence_run = 0
                    else:
                        silence_run += 1

                    # Emit a rolling partial if enough time has passed AND buffer grew.
                    now = time.monotonic()
                    grew_enough = (len(voiced) - last_partial_frames) >= partial_growth_frames
                    time_elapsed = (now - last_partial_ts) >= PARTIAL_INTERVAL_S
                    if time_elapsed and grew_enough and len(voiced) >= min_frames:
                        yield ("partial", np.concatenate(voiced))
                        last_partial_ts = now
                        last_partial_frames = len(voiced)

                    end_by_silence = silence_run >= end_silence_frames
                    end_by_length = len(voiced) >= max_frames
                    if end_by_silence or end_by_length:
                        if len(voiced) >= min_frames:
                            self.model.reset_states()
                            yield ("final", np.concatenate(voiced))
                        triggered = False
                        voiced = []
                        voiced_run = 0
                        silence_run = 0
                        last_partial_frames = 0
                        pre_roll.clear()


# ──────────────────────────────────────────────
# ASR client (mls / Qwen3-ASR)
# ──────────────────────────────────────────────

class MlsASRClient:
    """HTTP client for mls (MLX Local Serving) running Qwen3-ASR-1.7B."""

    def __init__(
        self,
        base_url: str = DEFAULT_MLS_URL,
        language: str | None = None,
        sample_rate: int = SAMPLE_RATE,
    ):
        self.api = f"{base_url.rstrip('/')}/transcribe"
        self.language = language
        self.sample_rate = sample_rate
        self._check(base_url)

    def _check(self, base_url: str):
        try:
            requests.get(base_url, timeout=5)
            print(f"[mls] Connected: {base_url}")
        except requests.ConnectionError:
            print(f"[mls] ERROR: Cannot reach mls at {base_url}", file=sys.stderr)
            print("[mls] Start it with: mls serve --asr Qwen/Qwen3-ASR-1.7B-8bit", file=sys.stderr)
            sys.exit(1)

    def transcribe(self, audio: np.ndarray) -> str:
        """Write the utterance to a temp WAV and hand mls the path."""
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            path = tmp.name
        try:
            sf.write(path, audio, self.sample_rate, subtype="PCM_16")
            payload: dict = {"path": path}
            if self.language:
                payload["language"] = self.language
            r = requests.post(self.api, json=payload, timeout=60)
            r.raise_for_status()
            return r.json().get("text", "").strip()
        except Exception as e:
            return f"[asr error: {e}]"
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass


# ──────────────────────────────────────────────
# Ollama translator
# ──────────────────────────────────────────────

class OllamaTranslator:
    """Calls local Ollama for translation, streaming output."""

    def __init__(
        self,
        model: str = DEFAULT_OLLAMA_MODEL,
        base_url: str = DEFAULT_OLLAMA_URL,
        target_lang: str = "Chinese",
    ):
        self.model = model
        self.api = f"{base_url}/api/chat"
        self.system_prompt = TRANSLATE_SYSTEM_PROMPT.format(target_lang=target_lang)
        self._check_model(base_url)
        self._warmup()

    def _check_model(self, base_url: str):
        """Verify model is available in Ollama."""
        try:
            r = requests.get(f"{base_url}/api/tags", timeout=5)
            models = [m["name"] for m in r.json().get("models", [])]
            # Match with or without tag
            matched = any(
                self.model in m or self.model.split(":")[0] in m for m in models
            )
            if matched:
                print(f"[ollama] Model '{self.model}' found.")
            else:
                print(f"[ollama] WARNING: '{self.model}' not found locally.")
                print(f"[ollama] Available: {models}")
                print(f"[ollama] Run: ollama pull {self.model}")
                sys.exit(1)
        except requests.ConnectionError:
            print("[ollama] ERROR: Cannot connect to Ollama at localhost:11434")
            print("[ollama] Run: ollama serve")
            sys.exit(1)

    def _warmup(self):
        """Force Ollama to load the model so the first real request isn't cold."""
        print(f"[ollama] Warming up '{self.model}'...")
        try:
            requests.post(
                self.api,
                json={
                    "model": self.model,
                    "messages": [{"role": "user", "content": "hi"}],
                    "stream": False,
                    "think": False,
                    "keep_alive": OLLAMA_KEEP_ALIVE,
                    "options": {"num_predict": 1},
                },
                timeout=120,
            )
            print("[ollama] Ready.")
        except Exception as e:
            print(f"[ollama] Warmup failed: {e}", file=sys.stderr)

    def translate(self, text: str) -> str:
        """Send text to Ollama, return translation. Non-streaming for simplicity."""
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": self.system_prompt},
                {"role": "user", "content": text},
            ],
            "stream": False,
            "think": False,
            "keep_alive": OLLAMA_KEEP_ALIVE,
            "options": {
                "temperature": 0.3,
                "top_p": 0.9,
                "num_predict": 512,
            },
        }
        try:
            r = requests.post(self.api, json=payload, timeout=30)
            r.raise_for_status()
            return r.json()["message"]["content"].strip()
        except Exception as e:
            return f"[translate error: {e}]"

    def translate_stream(self, text: str):
        """Send text to Ollama, yield translation tokens as they arrive."""
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": self.system_prompt},
                {"role": "user", "content": text},
            ],
            "stream": True,
            "think": False,
            "keep_alive": OLLAMA_KEEP_ALIVE,
            "options": {
                "temperature": 0.3,
                "top_p": 0.9,
                "num_predict": 512,
            },
        }
        try:
            r = requests.post(self.api, json=payload, timeout=30, stream=True)
            r.raise_for_status()
            for line in r.iter_lines():
                if line:
                    chunk = json.loads(line)
                    token = chunk.get("message", {}).get("content", "")
                    if token:
                        yield token
                    if chunk.get("done"):
                        break
        except Exception as e:
            yield f"[error: {e}]"


# ──────────────────────────────────────────────
# Partial transcription worker
# ──────────────────────────────────────────────

class PartialPipeline:
    """Background worker: ASR + non-streaming LLM translate on the latest partial audio,
    redraws the partial line in-place with \\r. Drops stale work when new audio arrives."""

    def __init__(self, asr, translator):
        self.asr = asr
        self.translator = translator
        self._latest: np.ndarray | None = None
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._frozen = threading.Event()
        self._display_lock = threading.Lock()
        self._last_text = ""
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def submit(self, audio: np.ndarray):
        with self._lock:
            self._latest = audio
        self._wake.set()

    def freeze(self):
        """Stop accepting partials and block until worker is idle. Call before final output."""
        self._frozen.set()
        # Grab the display lock to ensure no in-flight write is ongoing.
        with self._display_lock:
            pass

    def reset(self):
        """Prepare for the next utterance."""
        self._frozen.clear()
        self._last_text = ""
        with self._lock:
            self._latest = None

    def shutdown(self):
        self._stop.set()
        self._wake.set()
        self._thread.join(timeout=1.0)

    def _run(self):
        while not self._stop.is_set():
            self._wake.wait()
            self._wake.clear()
            if self._stop.is_set():
                return
            with self._lock:
                audio = self._latest
                self._latest = None
            if audio is None or self._frozen.is_set():
                continue
            try:
                text = self.asr.transcribe(audio)
                if self._frozen.is_set() or not text or text == self._last_text:
                    continue
                self._last_text = text
                translated = self.translator.translate(text)
                if self._frozen.is_set():
                    continue
                with self._display_lock:
                    if self._frozen.is_set():
                        continue
                    sys.stdout.write(f"\r\033[K{YELLOW}  ⟳  {translated}{RESET}")
                    sys.stdout.flush()
            except Exception as e:
                print(f"\n[partial error] {e}", file=sys.stderr)


# ──────────────────────────────────────────────
# Display
# ──────────────────────────────────────────────

# ANSI colors
CYAN = "\033[36m"
YELLOW = "\033[33m"
DIM = "\033[2m"
RESET = "\033[0m"
BOLD = "\033[1m"
GREEN = "\033[32m"


def print_header():
    print(f"""
{BOLD}╔══════════════════════════════════════════════╗
║   🎤  Local Real-Time Translator              ║
║   Silero VAD + Qwen3-ASR-1.7B + Qwen3.5-4B    ║
╚══════════════════════════════════════════════╝{RESET}
""")


# ──────────────────────────────────────────────
# Main pipeline
# ──────────────────────────────────────────────

def run(args):
    print_header()

    # Init components
    stt = MlsASRClient(base_url=args.mls_url, language=args.asr_lang)
    translator = OllamaTranslator(
        model=args.ollama_model,
        base_url=args.ollama_url,
        target_lang=args.target,
    )
    mic = VADSegmenter(sample_rate=SAMPLE_RATE, threshold=args.vad_threshold)

    partial_pipe = PartialPipeline(stt, translator)

    print(f"\n{DIM}Source: {args.asr_lang or 'auto'} → Target: {args.target}{RESET}")
    print(f"{DIM}ASR: Qwen3-ASR-1.7B (mls) | LLM: {args.ollama_model}{RESET}")
    print(f"{DIM}VAD: Silero (threshold={args.vad_threshold}) | end-silence={SPEECH_END_MS}ms | partial={PARTIAL_INTERVAL_S}s{RESET}\n")
    print(f"{DIM}{'─' * 50}{RESET}\n")

    seg_count = 0
    header_printed = False

    def print_header_once():
        nonlocal header_printed, seg_count
        if not header_printed:
            seg_count += 1
            ts = time.strftime("%H:%M:%S")
            print(f"{DIM}[{ts}] #{seg_count}{RESET}")
            header_printed = True

    try:
        for kind, audio in mic.events():
            if kind == "partial":
                print_header_once()
                partial_pipe.submit(audio)
                continue

            # kind == "final": quiesce the worker, then print the final block
            partial_pipe.freeze()
            print_header_once()
            # Clear the in-place partial line before printing the final block
            sys.stdout.write("\r\033[K")
            sys.stdout.flush()

            t0 = time.perf_counter()
            text = stt.transcribe(audio)
            stt_ms = (time.perf_counter() - t0) * 1000

            if not text or len(text.strip()) < 2:
                partial_pipe.reset()
                header_printed = False
                continue

            print(f"{CYAN}  ASR ({stt_ms:.0f}ms): {text}{RESET}")

            t0 = time.perf_counter()
            sys.stdout.write(f"{YELLOW}  >>>  ")
            sys.stdout.flush()
            for token in translator.translate_stream(text):
                sys.stdout.write(token)
                sys.stdout.flush()
            llm_ms = (time.perf_counter() - t0) * 1000
            print(f"{RESET}")
            print(f"{DIM}  ({llm_ms:.0f}ms){RESET}\n")

            partial_pipe.reset()
            header_printed = False
    finally:
        partial_pipe.shutdown()


def main():
    parser = argparse.ArgumentParser(
        description="Pure-local real-time translator: Qwen3-ASR (mls) + Qwen3.5 (Ollama)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  # Auto-detect → Chinese (default)
  python main.py

  # Japanese source → English target
  python main.py --asr-lang ja --target English

  # Swap the translator LLM
  python main.py --ollama-model qwen3.5:9b

  # Stricter VAD (cuts sooner in noisy rooms)
  python main.py --vad-threshold 0.7
""",
    )
    parser.add_argument(
        "--target", default="Chinese", help="Target language (default: Chinese)"
    )
    parser.add_argument(
        "--asr-lang",
        default=None,
        help="ASR source language hint (e.g. zh/en/ja); None = auto-detect",
    )
    parser.add_argument(
        "--mls-url",
        default=DEFAULT_MLS_URL,
        help=f"mls server URL (default: {DEFAULT_MLS_URL})",
    )
    parser.add_argument(
        "--ollama-model",
        default=DEFAULT_OLLAMA_MODEL,
        help=f"Ollama model (default: {DEFAULT_OLLAMA_MODEL})",
    )
    parser.add_argument(
        "--ollama-url",
        default=DEFAULT_OLLAMA_URL,
        help="Ollama API URL (default: http://localhost:11434)",
    )
    parser.add_argument(
        "--vad-threshold",
        type=float,
        default=VAD_THRESHOLD,
        help="Silero VAD speech probability threshold 0..1 (default: 0.5)",
    )
    args = parser.parse_args()

    try:
        run(args)
    except KeyboardInterrupt:
        print(f"\n\n{GREEN}Done. Bye!{RESET}")
        sys.exit(0)


if __name__ == "__main__":
    main()
