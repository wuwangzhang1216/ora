#!/usr/bin/env python3
"""
Pure-local real-time translator
Silero VAD + on-device ASR (via mls) + on-device translator LLM (via Ollama)

Architecture:
  Mic → sounddevice (16kHz PCM) → Silero VAD → utterance
      → mls HTTP (ASR, MLX) → text
      → Ollama HTTP (translator LLM, streaming) → translated text → terminal

No network calls. No API keys. Everything on-device (Metal GPU via MLX + Ollama).
"""

import argparse
from dataclasses import dataclass
from datetime import datetime
import json
import os
import queue
import shutil
import sys
import tempfile
import threading
import time
from collections import deque
from pathlib import Path

import numpy as np
import requests
import sounddevice as sd
import soundfile as sf
import torch
from silero_vad import load_silero_vad

from rich.console import Console, Group
from rich.live import Live
from rich.padding import Padding
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

# ──────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────

QUALITY_MODELS = {
    "standard":   "qwen3.5:2b",   # ~1.2 GB — default, fast
    "high":       "qwen3.5:4b",   # ~3 GB — better quality, slower
    "extra-high": "qwen3.5:9b",   # ~6 GB — best quality, slowest
}
DEFAULT_QUALITY = "standard"
DEFAULT_OLLAMA_MODEL = QUALITY_MODELS[DEFAULT_QUALITY]
DEFAULT_OLLAMA_URL = "http://localhost:11434"
DEFAULT_MLS_URL = "http://127.0.0.1:18321"
SAMPLE_RATE = 16000
VAD_FRAME_SAMPLES = 512           # Silero requires exactly 512 samples @ 16kHz (~32ms)
VAD_FRAME_MS = VAD_FRAME_SAMPLES * 1000 // SAMPLE_RATE
# VAD thresholds with hysteresis — avoid rapid toggling when speech probability
# hovers around the boundary. Start > stop by VAD_HYSTERESIS is the pattern
# recommended by Silero FAQ / Pipecat / LiveKit.
VAD_THRESHOLD = 0.5               # start-of-speech threshold (Silero default)
VAD_HYSTERESIS = 0.15             # gap below start threshold to end speech
VAD_STOP_THRESHOLD = max(0.0, VAD_THRESHOLD - VAD_HYSTERESIS)

SPEECH_START_FRAMES = 3           # ~96 ms of voiced frames to trigger start
SPEECH_END_MS = 500               # trailing silence to end an utterance (industry-standard balance)
PRE_ROLL_MS = 200                 # audio kept before speech start
MIN_UTTERANCE_MS = 300            # drop anything shorter
MAX_UTTERANCE_S = 15              # safety cap for run-on speech
PARTIAL_INTERVAL_S = 0.6          # rolling partial cadence (~500 ms is industry norm)
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

VAD_PRESETS = {
    "quiet": {
        "vad_threshold": 0.42,
        "end_silence_ms": 650,
        "partial_interval_s": 0.55,
        "description": "home office / headset mic",
    },
    "meeting": {
        "vad_threshold": 0.5,
        "end_silence_ms": 500,
        "partial_interval_s": 0.6,
        "description": "balanced default for calls and meetings",
    },
    "noisy": {
        "vad_threshold": 0.68,
        "end_silence_ms": 420,
        "partial_interval_s": 0.7,
        "description": "cafes, fans, shared rooms",
    },
}


@dataclass
class SegmentRecord:
    index: int
    timestamp: str
    source: str
    translation: str
    asr_ms: float
    llm_ms: float


class SessionRecorder:
    """Collect finalized translations and write a user-readable session file."""

    def __init__(self, path: Path | None, fmt: str):
        self.path = path
        self.fmt = fmt
        self.records: list[SegmentRecord] = []

    @property
    def enabled(self) -> bool:
        return self.path is not None

    def add(self, source: str, translation: str, asr_ms: float, llm_ms: float) -> None:
        self.records.append(
            SegmentRecord(
                index=len(self.records) + 1,
                timestamp=datetime.now().isoformat(timespec="seconds"),
                source=source,
                translation=translation,
                asr_ms=asr_ms,
                llm_ms=llm_ms,
            )
        )

    def write(self) -> Path | None:
        if not self.enabled or self.path is None:
            return None
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.fmt == "jsonl":
            body = "\n".join(json.dumps(r.__dict__, ensure_ascii=False) for r in self.records)
        elif self.fmt == "txt":
            body = self._txt()
        elif self.fmt == "srt":
            body = self._srt()
        else:
            body = self._md()
        if body and not body.endswith("\n"):
            body += "\n"
        self.path.write_text(body, encoding="utf-8")
        return self.path

    def _txt(self) -> str:
        lines = []
        for r in self.records:
            lines.extend(
                [
                    f"[{r.index}] {r.timestamp}",
                    f"SOURCE: {r.source}",
                    f"TRANSLATION: {r.translation}",
                    "",
                ]
            )
        return "\n".join(lines)

    def _md(self) -> str:
        lines = ["# Ora Session", "", f"Created: {datetime.now().isoformat(timespec='seconds')}", ""]
        for r in self.records:
            lines.extend(
                [
                    f"## {r.index}. {r.timestamp}",
                    "",
                    f"**Source**: {r.source}",
                    "",
                    f"**Translation**: {r.translation}",
                    "",
                    f"`ASR {r.asr_ms:.0f}ms`  `LLM {r.llm_ms:.0f}ms`",
                    "",
                ]
            )
        return "\n".join(lines)

    def _srt(self) -> str:
        lines = []
        for i, r in enumerate(self.records, start=1):
            start_s = max(0, (i - 1) * 4)
            end_s = start_s + 4
            lines.extend(
                [
                    str(i),
                    f"{_srt_time(start_s)} --> {_srt_time(end_s)}",
                    r.translation,
                    r.source,
                    "",
                ]
            )
        return "\n".join(lines)


def _srt_time(seconds: int) -> str:
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d},000"


def default_session_path(fmt: str) -> Path:
    ext = "md" if fmt == "markdown" else fmt
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return Path("sessions") / f"ora-session-{stamp}.{ext}"


def resolve_device_id(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        devices = sd.query_devices()
        matches = [
            idx
            for idx, dev in enumerate(devices)
            if dev.get("max_input_channels", 0) > 0
            and value.lower() in str(dev.get("name", "")).lower()
        ]
        if len(matches) == 1:
            return matches[0]
        if not matches:
            raise ValueError(f"No input device matches '{value}'")
        raise ValueError(f"Multiple input devices match '{value}': {matches}")


def input_devices_table() -> Table:
    table = Table(title="Input Devices", show_header=True, header_style="bold cyan")
    table.add_column("id", justify="right", style="dim")
    table.add_column("name")
    table.add_column("channels", justify="right")
    table.add_column("default rate", justify="right")
    try:
        default_input = sd.default.device[0]
        for idx, dev in enumerate(sd.query_devices()):
            channels = int(dev.get("max_input_channels", 0))
            if channels <= 0:
                continue
            name = str(dev.get("name", "Unknown"))
            if idx == default_input:
                name = f"{name} [green](default)[/]"
            table.add_row(
                str(idx),
                name,
                str(channels),
                f"{float(dev.get('default_samplerate', 0.0)):.0f} Hz",
            )
    except Exception as e:
        table.add_row("-", f"[red]{e}[/]", "-", "-")
    return table


def run_preflight(args, ui: "TranslatorUI") -> bool:
    """Friendly readiness screen before the real-time path opens the mic."""
    rows: list[tuple[str, bool, str]] = []

    rows.append(("Python deps", True, "loaded"))
    ollama_path = shutil.which("ollama")
    rows.append(("Ollama binary", ollama_path is not None, ollama_path or "install with: brew install ollama"))

    try:
        device_id = resolve_device_id(args.device)
        devices = sd.query_devices()
        device_name = devices[device_id]["name"] if device_id is not None else "system default"
        rows.append(("Microphone", True, str(device_name)))
    except Exception as e:
        rows.append(("Microphone", False, str(e)))

    try:
        requests.get(args.mls_url, timeout=2)
        rows.append(("mls ASR server", True, args.mls_url))
    except requests.ConnectionError:
        rows.append(("mls ASR server", False, "start with ./run.sh or run setup first"))
    except Exception as e:
        rows.append(("mls ASR server", False, str(e)))

    try:
        r = requests.get(f"{args.ollama_url.rstrip('/')}/api/tags", timeout=2)
        r.raise_for_status()
        models = [m["name"] for m in r.json().get("models", [])]
        matched = any(args.ollama_model in m or args.ollama_model.split(":")[0] in m for m in models)
        rows.append(("Translator model", matched, args.ollama_model if matched else f"pull with: ollama pull {args.ollama_model}"))
    except requests.ConnectionError:
        rows.append(("Ollama server", False, "start with: ollama serve"))
    except Exception as e:
        rows.append(("Ollama server", False, str(e)))

    table = Table(show_header=False, box=None, padding=(0, 1))
    table.add_column("status", width=2)
    table.add_column("check")
    table.add_column("detail", style="dim")
    for label, ok, detail in rows:
        table.add_row("[green]✓[/]" if ok else "[red]✗[/]", label, detail)

    ok_all = all(ok for _, ok, _ in rows)
    border = "green" if ok_all else "yellow"
    title = "[bold green]Ready[/]" if ok_all else "[bold yellow]Needs attention[/]"
    ui.console.print(Panel(table, title=title, border_style=border))
    if not ok_all:
        ui.console.print("[dim]Tip: ./run.sh starts the local services it can manage; ./setup.sh installs missing pieces.[/]\n")
    return ok_all


# ──────────────────────────────────────────────
# UI (rich Live + bottom status bar)
# ──────────────────────────────────────────────

LEVEL_BARS = "▁▂▃▄▅▆▇█"
LEVEL_HISTORY = 28

STATE_LABELS = {
    "booting":      ("[dim]○[/]",         "dim",     "booting"),
    "listening":    ("[cyan]●[/]",        "cyan",    "listening"),
    "speaking":     ("[green]●[/]",       "green",   "speaking"),
    "transcribing": ("[magenta]◐[/]",     "magenta", "transcribing"),
    "translating":  ("[yellow]◑[/]",      "yellow",  "translating"),
}


class _StatusRenderable:
    """Thin wrapper so Live re-reads UI state on every refresh tick."""

    def __init__(self, ui: "TranslatorUI"):
        self.ui = ui

    def __rich__(self):
        return self.ui._render_status()


class TranslatorUI:
    """Terminal UX: rich Live bottom status bar + cards for finalized utterances."""

    def __init__(
        self,
        *,
        target_lang: str,
        asr_lang: str | None,
        asr_model: str,
        llm_model: str,
        vad_threshold: float,
        end_silence_ms: int,
        partial_interval_s: float,
    ):
        self.console = Console(highlight=False)
        self.target_lang = target_lang
        self.asr_lang = asr_lang
        self.asr_model = asr_model
        self.llm_model = llm_model
        self.vad_threshold = vad_threshold
        self.end_silence_ms = end_silence_ms
        self.partial_interval_s = partial_interval_s

        self._lock = threading.Lock()
        self._state = "booting"
        self._vad_history: deque[float] = deque([0.0] * LEVEL_HISTORY, maxlen=LEVEL_HISTORY)
        self._partial_asr = ""
        self._partial_translation = ""
        self._seg_count = 0
        self._sum_asr_ms = 0.0
        self._sum_llm_ms = 0.0
        self._start_time = time.monotonic()
        self._live: Live | None = None

    # ── pre-Live logging (also usable while Live is active) ──

    def info(self, msg: str):
        self.console.print(f"[dim]·[/] [dim]{msg}[/]")

    def ok(self, msg: str):
        self.console.print(f"[green]✓[/] [dim]{msg}[/]")

    def warn(self, msg: str):
        self.console.print(f"[yellow]![/] {msg}")

    def err(self, msg: str):
        self.console.print(f"[red]✗[/] {msg}")

    def print_banner(self):
        title = Text("🎤  Local Real-Time Translator", style="bold cyan", justify="center")
        body = Table.grid(padding=(0, 2))
        body.add_column(style="dim", justify="right")
        body.add_column()
        body.add_row("source", f"{self.asr_lang or 'auto'}  →  [bold]{self.target_lang}[/]")
        body.add_row("asr", self.asr_model)
        body.add_row("llm", self.llm_model)
        body.add_row(
            "vad",
            f"threshold={self.vad_threshold}  end-silence={self.end_silence_ms}ms  "
            f"partial={self.partial_interval_s}s",
        )
        self.console.print(Panel(Group(title, Text(""), body), border_style="cyan", padding=(0, 2)))
        self.console.print()

    # ── state mutations (called from VAD / pipeline threads) ──

    def set_state(self, state: str):
        with self._lock:
            self._state = state

    def push_vad_level(self, prob: float):
        with self._lock:
            self._vad_history.append(max(0.0, min(1.0, prob)))

    def set_partial_asr(self, text: str):
        with self._lock:
            self._partial_asr = text

    def set_partial_translation(self, text: str):
        with self._lock:
            self._partial_translation = text

    def clear_partial(self):
        with self._lock:
            self._partial_asr = ""
            self._partial_translation = ""

    # ── finalized utterance card (printed above the Live region) ──

    def log_utterance(self, asr_text: str, translation: str, asr_ms: float, llm_ms: float):
        with self._lock:
            self._seg_count += 1
            self._sum_asr_ms += asr_ms
            self._sum_llm_ms += llm_ms
            idx = self._seg_count
        ts = time.strftime("%H:%M:%S")

        header = Text.assemble(
            ("  ", ""),
            (f"[{ts}]", "dim"),
            ("  ", ""),
            (f"#{idx}", "bold dim"),
        )
        src = Text.assemble(("  src  ", "cyan bold"), (asr_text, "white"))
        tra = Text.assemble(("  ▸    ", "yellow bold"), (translation, "bold yellow"))
        meta = Text(
            f"         ASR {asr_ms:.0f}ms  ·  LLM {llm_ms:.0f}ms",
            style="dim",
        )
        self.console.print(Group(header, src, tra, meta, Text("")))

    # ── status bar rendering ──

    def _level_bar(self) -> Text:
        bars_n = len(LEVEL_BARS)
        threshold = self.vad_threshold
        out = Text()
        for p in self._vad_history:
            ch = LEVEL_BARS[min(bars_n - 1, int(p * bars_n))]
            style = "green" if p >= threshold else ("cyan" if p > 0.15 else "dim")
            out.append(ch, style=style)
        return out

    def _elapsed(self) -> str:
        t = int(time.monotonic() - self._start_time)
        h, rem = divmod(t, 3600)
        m, s = divmod(rem, 60)
        return f"{h}h{m:02d}m{s:02d}s" if h else f"{m}m{s:02d}s"

    def _render_status(self) -> Panel:
        with self._lock:
            state = self._state
            partial_asr = self._partial_asr
            partial_tr = self._partial_translation
            count = self._seg_count
            avg_asr = self._sum_asr_ms / count if count else 0.0
            avg_llm = self._sum_llm_ms / count if count else 0.0
            level = self._level_bar()

        icon, border, label = STATE_LABELS.get(state, STATE_LABELS["listening"])

        top = Table.grid(expand=True)
        top.add_column(ratio=1)
        top.add_column(justify="right")
        top.add_row(
            Text.from_markup(f"{icon}  [bold]{label}[/]  ") + level,
            Text.from_markup(f"[dim]{self._elapsed()}  ·  {count} utts[/]"),
        )

        active = bool(partial_asr or partial_tr) or state in ("speaking", "transcribing", "translating")

        src_prefix = Text.from_markup("[cyan bold]src[/]  ")
        tra_prefix = Text.from_markup("[yellow bold]▸  [/]  ")

        if partial_asr:
            src_body = Text(partial_asr, style="white", no_wrap=True, overflow="ellipsis")
        elif active:
            src_body = Text.from_markup("[dim]…[/]")
        else:
            src_body = Text.from_markup("[dim](waiting for speech — Ctrl+C to quit)[/]")

        if partial_tr:
            tra_body = Text(partial_tr, style="bold yellow", no_wrap=True, overflow="ellipsis")
        elif active:
            tra_body = Text.from_markup("[dim]…[/]")
        else:
            tra_body = Text.from_markup("[dim]—[/]")

        src_line = src_prefix + src_body
        tra_line = tra_prefix + tra_body

        if count:
            stats = Text.from_markup(
                f"[dim]avg  ASR {avg_asr:.0f}ms  ·  LLM {avg_llm:.0f}ms[/]"
            )
        else:
            stats = Text.from_markup("[dim]avg  —[/]")

        body = Group(top, src_line, tra_line, stats)
        return Panel(body, border_style=border, padding=(0, 1), title=None, height=6)

    # ── Live lifecycle ──

    def __enter__(self):
        self._start_time = time.monotonic()
        self._live = Live(
            _StatusRenderable(self),
            console=self.console,
            refresh_per_second=15,
            transient=False,
        )
        self._live.start()
        return self

    def __exit__(self, exc_type, exc, tb):
        if self._live is not None:
            self._live.stop()
            self._live = None

    def print_summary(self):
        with self._lock:
            count = self._seg_count
            avg_asr = self._sum_asr_ms / count if count else 0.0
            avg_llm = self._sum_llm_ms / count if count else 0.0
            elapsed = self._elapsed()
        if count:
            body = Text.from_markup(
                f"[green]✓[/] Translated [bold]{count}[/] utterances in [bold]{elapsed}[/]\n"
                f"[dim]avg  ASR {avg_asr:.0f}ms  ·  LLM {avg_llm:.0f}ms[/]"
            )
        else:
            body = Text.from_markup(f"[dim]No utterances. Ran for {elapsed}.[/]")
        self.console.print(Panel(body, title="[bold green]Session Summary[/]", border_style="green"))


# ──────────────────────────────────────────────
# Audio capture
# ──────────────────────────────────────────────

class VADSegmenter:
    """Mic capture with Silero VAD endpointing. Yields one utterance per speech span."""

    def __init__(
        self,
        ui: TranslatorUI,
        sample_rate: int = SAMPLE_RATE,
        start_threshold: float = VAD_THRESHOLD,
        stop_threshold: float | None = None,
        end_silence_ms: int = SPEECH_END_MS,
        partial_interval_s: float = PARTIAL_INTERVAL_S,
        input_device: int | None = None,
    ):
        self.ui = ui
        self.sample_rate = sample_rate
        self.start_threshold = start_threshold
        self.stop_threshold = (
            stop_threshold
            if stop_threshold is not None
            else max(0.0, start_threshold - VAD_HYSTERESIS)
        )
        self.end_silence_ms = end_silence_ms
        self.partial_interval_s = partial_interval_s
        self.input_device = input_device
        self.model = load_silero_vad()
        self.q: queue.Queue[np.ndarray] = queue.Queue()

    def _callback(self, indata, frames, time_info, status):
        if status:
            self.ui.warn(f"audio: {status}")
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

    def _prob(self, frame: np.ndarray) -> float:
        with torch.no_grad():
            return self.model(torch.from_numpy(frame), self.sample_rate).item()

    def events(self):
        """Yield ('partial', audio) during speech and ('final', audio) at end-of-speech."""
        pre_roll_frames = max(1, PRE_ROLL_MS // VAD_FRAME_MS)
        end_silence_frames = max(1, self.end_silence_ms // VAD_FRAME_MS)
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
            device=self.input_device,
            callback=self._callback,
        ):
            self.ui.set_state("listening")
            for frame in self._frames():
                prob = self._prob(frame)
                self.ui.push_vad_level(prob)

                # Hysteresis: use the HIGHER start threshold to decide when
                # speech begins, and the LOWER stop threshold to decide
                # silence while already in a speech region. Prevents rapid
                # toggling around a single boundary.
                if not triggered:
                    is_speech = prob >= self.start_threshold
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
                            self.ui.set_state("speaking")
                    else:
                        voiced_run = 0
                else:
                    is_still_speech = prob >= self.stop_threshold
                    voiced.append(frame)
                    if is_still_speech:
                        silence_run = 0
                    else:
                        silence_run += 1

                    # Emit a rolling partial if enough time has passed AND buffer grew.
                    now = time.monotonic()
                    grew_enough = (len(voiced) - last_partial_frames) >= partial_growth_frames
                    time_elapsed = (now - last_partial_ts) >= self.partial_interval_s
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
                        self.ui.set_state("listening")


# ──────────────────────────────────────────────
# ASR client (mls / Qwen3-ASR)
# ──────────────────────────────────────────────

class MlsASRClient:
    """HTTP client for mls (MLX Local Serving) running Qwen3-ASR-1.7B."""

    def __init__(
        self,
        ui: TranslatorUI,
        base_url: str = DEFAULT_MLS_URL,
        language: str | None = None,
        sample_rate: int = SAMPLE_RATE,
    ):
        self.ui = ui
        self.api = f"{base_url.rstrip('/')}/transcribe"
        self.language = language
        self.sample_rate = sample_rate
        self._check(base_url)

    def _check(self, base_url: str):
        try:
            requests.get(base_url, timeout=5)
        except requests.ConnectionError:
            self.ui.err(f"Cannot reach mls at {base_url}")
            self.ui.info("Start it with: mls serve --asr Qwen/Qwen3-ASR-1.7B-8bit")
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
        ui: TranslatorUI,
        model: str = DEFAULT_OLLAMA_MODEL,
        base_url: str = DEFAULT_OLLAMA_URL,
        target_lang: str = "Chinese",
    ):
        self.ui = ui
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
            matched = any(
                self.model in m or self.model.split(":")[0] in m for m in models
            )
            if not matched:
                self.ui.err(f"Ollama model '{self.model}' not found locally")
                self.ui.info(f"Available: {', '.join(models) or '(none)'}")
                self.ui.info(f"Run: ollama pull {self.model}")
                sys.exit(1)
        except requests.ConnectionError:
            self.ui.err("Cannot connect to Ollama at localhost:11434")
            self.ui.info("Run: ollama serve")
            sys.exit(1)

    def _warmup(self):
        """Force Ollama to load the model so the first real request isn't cold."""
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
        except Exception as e:
            self.ui.warn(f"Ollama warmup failed: {e}")

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
    """Background worker: ASR + non-streaming LLM translate on the latest partial audio.
    Publishes results into the UI status bar. Drops stale work when new audio arrives."""

    def __init__(self, asr: MlsASRClient, translator: OllamaTranslator, ui: TranslatorUI):
        self.asr = asr
        self.translator = translator
        self.ui = ui
        self._latest: np.ndarray | None = None
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._frozen = threading.Event()
        self._last_text = ""
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def submit(self, audio: np.ndarray):
        with self._lock:
            self._latest = audio
        self._wake.set()

    def freeze(self):
        """Stop accepting partials. Call before final output."""
        self._frozen.set()

    def reset(self):
        """Prepare for the next utterance."""
        self._frozen.clear()
        self._last_text = ""
        with self._lock:
            self._latest = None
        self.ui.clear_partial()

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
                self.ui.set_partial_asr(text)
                translated = self.translator.translate(text)
                if self._frozen.is_set():
                    continue
                self.ui.set_partial_translation(translated)
            except Exception as e:
                self.ui.warn(f"partial error: {e}")


# ──────────────────────────────────────────────
# Main pipeline
# ──────────────────────────────────────────────

def run(args):
    ui = TranslatorUI(
        target_lang=args.target,
        asr_lang=args.asr_lang,
        asr_model="on-device (mls)",
        llm_model=args.quality_label,
        vad_threshold=args.vad_threshold,
        end_silence_ms=args.end_silence_ms,
        partial_interval_s=args.partial_interval_s,
    )
    ui.print_banner()

    if not args.skip_preflight and not run_preflight(args, ui):
        sys.exit(2)

    try:
        input_device = resolve_device_id(args.device)
    except ValueError as e:
        ui.err(str(e))
        sys.exit(2)

    recorder = SessionRecorder(args.session_file, args.output_format)

    # Boot components with spinners above the (not-yet-started) Live region.
    with ui.console.status("[cyan]Loading Silero VAD…", spinner="dots"):
        mic = VADSegmenter(
            ui,
            sample_rate=SAMPLE_RATE,
            start_threshold=args.vad_threshold,
            end_silence_ms=args.end_silence_ms,
            partial_interval_s=args.partial_interval_s,
            input_device=input_device,
        )
    ui.ok("Silero VAD ready")

    with ui.console.status(f"[cyan]Connecting to mls at {args.mls_url}…", spinner="dots"):
        stt = MlsASRClient(ui, base_url=args.mls_url, language=args.asr_lang)
    ui.ok(f"mls connected  [dim]({args.mls_url})[/]")

    with ui.console.status(f"[cyan]Warming up translator ({args.quality_label})…", spinner="dots"):
        translator = OllamaTranslator(
            ui,
            model=args.ollama_model,
            base_url=args.ollama_url,
            target_lang=args.target,
        )
    ui.ok(f"Translator ready  [dim]({args.quality_label})[/]")
    ui.console.print()

    partial_pipe = PartialPipeline(stt, translator, ui)

    try:
        with ui:
            for kind, audio in mic.events():
                if kind == "partial":
                    partial_pipe.submit(audio)
                    continue

                # kind == "final": quiesce the worker, then print the final card.
                partial_pipe.freeze()
                ui.set_state("transcribing")
                ui.set_partial_translation("")

                t0 = time.perf_counter()
                text = stt.transcribe(audio)
                asr_ms = (time.perf_counter() - t0) * 1000

                if not text or len(text.strip()) < 2:
                    partial_pipe.reset()
                    ui.set_state("listening")
                    continue

                ui.set_partial_asr(text)
                ui.set_state("translating")

                t0 = time.perf_counter()
                buffer = ""
                for token in translator.translate_stream(text):
                    buffer += token
                    ui.set_partial_translation(buffer)
                llm_ms = (time.perf_counter() - t0) * 1000

                ui.log_utterance(text, buffer, asr_ms, llm_ms)
                recorder.add(text, buffer, asr_ms, llm_ms)
                partial_pipe.reset()
                ui.set_state("listening")
    except KeyboardInterrupt:
        pass
    finally:
        partial_pipe.shutdown()
        written = recorder.write()
        ui.print_summary()
        if written:
            ui.ok(f"Session saved to {written}")


def run_demo(args):
    ui = TranslatorUI(
        target_lang=args.target,
        asr_lang=args.asr_lang,
        asr_model="demo ASR",
        llm_model=f"{args.quality_label} demo",
        vad_threshold=args.vad_threshold,
        end_silence_ms=args.end_silence_ms,
        partial_interval_s=args.partial_interval_s,
    )
    ui.print_banner()
    recorder = SessionRecorder(args.session_file, args.output_format)
    samples = [
        (
            "我们今天先把产品体验打磨得更顺一点。",
            "Today, let's first make the product experience feel smoother.",
        ),
        (
            "Can you keep the subtitles compact during a meeting?",
            "你可以在会议期间让字幕保持紧凑吗？",
        ),
        (
            "専門用語は用語集に入れて、翻訳を安定させたいです。",
            "I want to add technical terms to the glossary so translation stays consistent.",
        ),
    ]

    with ui:
        for source, translation in samples:
            ui.set_state("speaking")
            ui.clear_partial()
            for p in (0.18, 0.33, 0.62, 0.78, 0.54, 0.72, 0.41):
                ui.push_vad_level(p)
                time.sleep(args.demo_speed)
            pieces = source.split()
            if len(pieces) <= 1:
                pieces = [source[: i + 6] for i in range(0, len(source), 6)]
            for i in range(1, len(pieces) + 1):
                ui.set_partial_asr(" ".join(pieces[:i]) if " " in source else pieces[i - 1])
                time.sleep(args.demo_speed)
            ui.set_state("transcribing")
            time.sleep(args.demo_speed * 2)
            ui.set_state("translating")
            buffer = ""
            for token in translation.split(" "):
                buffer = f"{buffer} {token}".strip()
                ui.set_partial_translation(buffer)
                time.sleep(args.demo_speed)
            asr_ms = 180 + len(source) * 2
            llm_ms = 260 + len(translation) * 3
            ui.log_utterance(source, translation, asr_ms, llm_ms)
            recorder.add(source, translation, asr_ms, llm_ms)
            ui.clear_partial()
            ui.set_state("listening")
            time.sleep(args.demo_speed * 3)
    written = recorder.write()
    ui.print_summary()
    if written:
        ui.ok(f"Session saved to {written}")


def main():
    parser = argparse.ArgumentParser(
        description="Pure-local real-time translator: on-device ASR (mls) + on-device LLM (Ollama)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  # Auto-detect → Chinese (default, Standard quality)
  python main.py

  # Japanese source → English target
  python main.py --asr-lang ja --target English

  # Bump translation quality
  python main.py --quality high
  python main.py --quality extra-high

  # Run a visual demo without mic / mls / Ollama
  python main.py --demo --save-session --output-format markdown

  # Tune for a noisy room and choose a microphone
  python main.py --preset noisy --list-devices
  python main.py --preset noisy --device "MacBook Pro Microphone"
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
        "--quality",
        choices=list(QUALITY_MODELS.keys()),
        default=DEFAULT_QUALITY,
        help=f"Translator quality tier (default: {DEFAULT_QUALITY})",
    )
    parser.add_argument(
        "--ollama-model",
        default=None,
        help="Override the Ollama model id (bypasses --quality)",
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
    parser.add_argument(
        "--end-silence-ms",
        type=int,
        default=None,
        help="Silence window that ends an utterance; defaults to the selected preset",
    )
    parser.add_argument(
        "--partial-interval",
        dest="partial_interval_s",
        type=float,
        default=None,
        help="Seconds between rolling partial captions; defaults to the selected preset",
    )
    parser.add_argument(
        "--preset",
        choices=list(VAD_PRESETS.keys()),
        default="meeting",
        help="VAD tuning preset: quiet, meeting, or noisy (default: meeting)",
    )
    parser.add_argument(
        "--device",
        default=None,
        help="Input device id or name substring; use --list-devices to inspect",
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="Show microphone input devices and exit",
    )
    parser.add_argument(
        "--skip-preflight",
        action="store_true",
        help="Skip startup readiness checks",
    )
    parser.add_argument(
        "--save-session",
        action="store_true",
        help="Save finalized source/translation pairs after the run",
    )
    parser.add_argument(
        "--session-file",
        type=Path,
        default=None,
        help="Where to write the session transcript",
    )
    parser.add_argument(
        "--output-format",
        choices=["markdown", "txt", "jsonl", "srt"],
        default="markdown",
        help="Session transcript format (default: markdown)",
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Run a visual terminal demo without opening the mic or local services",
    )
    parser.add_argument(
        "--demo-speed",
        type=float,
        default=0.08,
        help="Delay between demo UI frames in seconds (default: 0.08)",
    )
    args = parser.parse_args()

    if args.ollama_model:
        args.quality_label = args.ollama_model
    else:
        args.ollama_model = QUALITY_MODELS[args.quality]
        args.quality_label = args.quality.replace("-", " ").title()

    preset = VAD_PRESETS[args.preset]
    if args.vad_threshold == VAD_THRESHOLD:
        args.vad_threshold = preset["vad_threshold"]
    if args.end_silence_ms is None:
        args.end_silence_ms = preset["end_silence_ms"]
    if args.partial_interval_s is None:
        args.partial_interval_s = preset["partial_interval_s"]
    if args.session_file is None and args.save_session:
        args.session_file = default_session_path(args.output_format)

    if args.list_devices:
        Console(highlight=False).print(input_devices_table())
        return

    if args.demo:
        run_demo(args)
    else:
        run(args)


if __name__ == "__main__":
    main()
