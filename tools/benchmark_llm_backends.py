#!/usr/bin/env python3
"""Benchmark local Ora translator LLM backends without mic or ASR noise."""

from __future__ import annotations

import argparse
import json
import statistics
import time
from dataclasses import dataclass

import requests


DEFAULT_SENTENCES = [
    "Good morning everyone, thanks for joining on short notice.",
    "Could you walk me through the latency numbers from yesterday's demo?",
    "I think the model is hallucinating when the speaker pauses mid sentence.",
    "Let's ship the safe version first and keep the faster path behind a flag.",
    "The next meeting starts in five minutes, so please summarize only the blockers.",
    "If the network is unavailable, the app should continue translating locally.",
]

TRANSLATE_SYSTEM_PROMPT = """\
You are a real-time speech translator. Translate the user's text into {target_lang}.
Rules:
- Output ONLY the translation. No explanations, no quotes, no markdown.
- Preserve the original tone and register.
- If the input is already in {target_lang}, output it unchanged.
- Translate even short fragments, hesitations ("uh", "嗯"), and incomplete sentences literally.
- Never output an empty response; if truly nothing to translate, echo the input.\
"""


def build_translation_prompt(target_lang: str, text: str) -> str:
    return f"Translate to {target_lang}. Output only the translation.\n\nSource: {text}\n{target_lang}: "


@dataclass
class Result:
    backend: str
    run: int
    text: str
    ok: bool
    ttft_ms: float | None
    total_ms: float
    output_chars: int
    output: str = ""
    error: str | None = None


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * pct)))
    return ordered[idx]


class OllamaClient:
    def __init__(self, base_url: str, model: str, target_lang: str):
        self.backend = "ollama"
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api = f"{self.base_url}/api/chat"
        self.system_prompt = TRANSLATE_SYSTEM_PROMPT.format(target_lang=target_lang)

    def check(self) -> None:
        r = requests.get(f"{self.base_url}/api/tags", timeout=5)
        r.raise_for_status()

    def request(self, text: str) -> tuple[float | None, float, str]:
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": self.system_prompt},
                {"role": "user", "content": text},
            ],
            "stream": True,
            "think": False,
            "keep_alive": "24h",
            "options": {"temperature": 0.3, "top_p": 0.9, "num_predict": 512},
        }
        return stream_json_lines(self.api, payload, ollama_token)


class RapidMLXClient:
    def __init__(self, base_url: str, model: str, target_lang: str):
        self.backend = "rapid-mlx"
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api = f"{self.base_url}/chat/completions"
        self.target_lang = target_lang

    def check(self) -> None:
        r = requests.get(f"{self.base_url}/models", timeout=5)
        r.raise_for_status()

    def request(self, text: str) -> tuple[float | None, float, str]:
        payload = {
            "model": self.model,
            "messages": [{"role": "user", "content": build_translation_prompt(self.target_lang, text)}],
            "stream": True,
            "temperature": 0.3,
            "top_p": 0.9,
            "max_tokens": 512,
        }
        return stream_json_lines(self.api, payload, openai_token)


def ollama_token(chunk: dict) -> str:
    return chunk.get("message", {}).get("content", "")


def openai_token(chunk: dict) -> str:
    choices = chunk.get("choices", [])
    if not choices:
        return ""
    return choices[0].get("delta", {}).get("content") or ""


def stream_json_lines(api: str, payload: dict, token_reader) -> tuple[float | None, float, str]:
    start = time.perf_counter()
    first_token_at: float | None = None
    pieces: list[str] = []
    with requests.post(api, json=payload, timeout=120, stream=True) as r:
        r.raise_for_status()
        for raw_line in r.iter_lines(decode_unicode=True):
            if not raw_line:
                continue
            if isinstance(raw_line, bytes):
                raw_line = raw_line.decode("utf-8")
            line = raw_line.strip()
            if line.startswith("data:"):
                line = line.removeprefix("data:").strip()
            if line == "[DONE]":
                break
            chunk = json.loads(line)
            token = token_reader(chunk)
            if token:
                if first_token_at is None:
                    first_token_at = time.perf_counter()
                pieces.append(token)
            if chunk.get("done"):
                break
    end = time.perf_counter()
    ttft_ms = None if first_token_at is None else (first_token_at - start) * 1000
    return ttft_ms, (end - start) * 1000, "".join(pieces).strip()


def load_sentences(path: str | None) -> list[str]:
    if not path:
        return DEFAULT_SENTENCES
    with open(path, encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]


def run_client(client, sentences: list[str], runs: int, warmup: int) -> list[Result]:
    client.check()
    for i in range(warmup):
        client.request(sentences[i % len(sentences)])

    results: list[Result] = []
    for run in range(1, runs + 1):
        for text in sentences:
            try:
                ttft_ms, total_ms, output = client.request(text)
                results.append(
                    Result(
                        backend=client.backend,
                        run=run,
                        text=text,
                        ok=bool(output),
                        ttft_ms=ttft_ms,
                        total_ms=total_ms,
                        output_chars=len(output),
                        output=output,
                    )
                )
            except Exception as e:
                results.append(
                    Result(
                        backend=client.backend,
                        run=run,
                        text=text,
                        ok=False,
                        ttft_ms=None,
                        total_ms=0.0,
                        output_chars=0,
                        error=str(e),
                    )
                )
    return results


def print_summary(results: list[Result]) -> None:
    by_backend: dict[str, list[Result]] = {}
    for result in results:
        by_backend.setdefault(result.backend, []).append(result)

    print("\nSummary")
    print("backend      ok/total  ttft_med  ttft_p95  total_med  total_p95  chars_med")
    for backend, items in by_backend.items():
        ok_items = [r for r in items if r.ok]
        ttfts = [r.ttft_ms for r in ok_items if r.ttft_ms is not None]
        totals = [r.total_ms for r in ok_items]
        chars = [r.output_chars for r in ok_items]
        print(
            f"{backend:<12} "
            f"{len(ok_items):>2}/{len(items):<5} "
            f"{statistics.median(ttfts) if ttfts else 0:>8.0f} "
            f"{percentile(ttfts, 0.95):>8.0f} "
            f"{statistics.median(totals) if totals else 0:>9.0f} "
            f"{percentile(totals, 0.95):>9.0f} "
            f"{statistics.median(chars) if chars else 0:>9.0f}"
        )

    failures = [r for r in results if not r.ok]
    if failures:
        print("\nFailures")
        for failure in failures[:10]:
            print(f"- {failure.backend}: {failure.error or 'empty output'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["ollama", "rapid-mlx", "both"], default="both")
    parser.add_argument("--target", default="Chinese")
    parser.add_argument("--sentences-file", default=None)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--ollama-url", default="http://localhost:11434")
    parser.add_argument("--ollama-model", default="qwen3.5:4b")
    parser.add_argument("--rapid-mlx-url", default="http://localhost:8000/v1")
    parser.add_argument("--rapid-mlx-model", default="default")
    parser.add_argument("--jsonl", default=None, help="Optional path for raw JSONL results")
    args = parser.parse_args()

    sentences = load_sentences(args.sentences_file)
    clients = []
    if args.backend in {"ollama", "both"}:
        clients.append(OllamaClient(args.ollama_url, args.ollama_model, args.target))
    if args.backend in {"rapid-mlx", "both"}:
        clients.append(RapidMLXClient(args.rapid_mlx_url, args.rapid_mlx_model, args.target))

    all_results: list[Result] = []
    for client in clients:
        print(f"Running {client.backend} ...")
        all_results.extend(run_client(client, sentences, args.runs, args.warmup))

    if args.jsonl:
        with open(args.jsonl, "w", encoding="utf-8") as f:
            for result in all_results:
                f.write(json.dumps(result.__dict__, ensure_ascii=False) + "\n")

    print_summary(all_results)


if __name__ == "__main__":
    main()
