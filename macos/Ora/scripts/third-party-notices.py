"""Preserve the license notices shipped with resolved source dependencies."""
from pathlib import Path
import sys

checkouts, output = map(Path, sys.argv[1:])
repo = Path(__file__).resolve().parents[3]
parts = ["Ora — Open Source Notices\n\n" + (repo / "LICENSE").read_text()]
for package in sorted(checkouts.iterdir()):
    if not package.is_dir():
        continue
    # Include vendored licenses as well as top-level dependency licenses.
    files = sorted(p for p in package.rglob("*") if p.is_file()
                   and p.name.lower().startswith(("license", "copying", "notice"))
                   and ".git" not in p.parts
                   and p.suffix.lower() not in {".swift", ".cpp", ".h", ".json"})
    for source in files:
        try:
            content = source.read_text()
        except (UnicodeError, OSError):
            continue
        parts.append(f"\n{'=' * 72}\n{package.name}/{source.relative_to(package)}\n{'=' * 72}\n\n{content}")
parts.append("""
Downloaded model assets (not included in the application download):

Qwen recognition: aufklarer/Qwen3-ASR-1.7B-MLX-8bit, based on Qwen/Qwen3-ASR-1.7B — Apache-2.0
https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-8bit

Qwen translation: mlx-community/Qwen3.5-{2B,4B,9B}-MLX-4bit — Apache-2.0
https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-4bit
https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit
https://huggingface.co/mlx-community/Qwen3.5-9B-MLX-4bit

Silero VAD CoreML: aufklarer/Silero-VAD-v6.2.1-CoreML — MIT
https://huggingface.co/aufklarer/Silero-VAD-v6.2.1-CoreML

Optional Nemotron: aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8 — OpenMDW-1.1
https://huggingface.co/aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8

Model licenses and attribution notices are available in the linked repositories.
The included Apache-2.0 and MIT dependency license texts do not change those model terms.
""")
for model_license in sorted((repo / "macos/Ora/Resources/ModelLicenses").glob("*.txt")):
    parts.append(f"\n{model_license.name}\n\n" + model_license.read_text())
output.write_text("\n".join(parts))
