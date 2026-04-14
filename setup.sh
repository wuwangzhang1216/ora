#!/bin/bash
# One-shot installer. Run once; `run.sh` handles the rest.
set -e

BOLD='\033[1m'; GREEN='\033[32m'; CYAN='\033[36m'; YELLOW='\033[33m'; RESET='\033[0m'

echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   🔧  Local Translator Setup (macOS)          ║"
echo -e "╚══════════════════════════════════════════════╝${RESET}\n"

# ── 1. Homebrew ──
if ! command -v brew &> /dev/null; then
    echo -e "${YELLOW}[!] Homebrew not found. Installing...${RESET}"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# ── 2. portaudio (sounddevice dep) ──
echo -e "${CYAN}[1/5] Installing portaudio...${RESET}"
brew install portaudio 2>/dev/null || echo "  portaudio already installed"

# ── 3. Ollama ──
echo -e "${CYAN}[2/5] Installing Ollama...${RESET}"
if ! command -v ollama &> /dev/null; then
    brew install ollama
else
    echo "  Ollama already installed"
fi

# ── 4. uv (fast Python package/venv manager) ──
if ! command -v uv &> /dev/null; then
    echo -e "${CYAN}[3a/5] Installing uv...${RESET}"
    brew install uv
fi

# ── 5. Translator venv + deps (via uv, pinned Python) ──
echo -e "${CYAN}[3/5] Creating translator venv...${RESET}"
if [ ! -f ".venv/bin/activate" ]; then
    rm -rf .venv
    uv venv --python 3.12 .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
uv pip install -r requirements.txt
uv pip install huggingface_hub

# ── 6. Clone + install mls (source-only project, no pyproject.toml) ──
echo -e "${CYAN}[3b/5] Setting up mls (ASR server)...${RESET}"
if [ ! -d ".mls" ]; then
    git clone https://github.com/hanxiao/mls .mls
fi
# Build mls's own venv with a stable Python — avoid the broken 3.14 ensurepip
# and mls's setup.sh which uses system python3.
if [ ! -f ".mls/.venv/bin/activate" ]; then
    rm -rf .mls/.venv
    (cd .mls && uv venv --python 3.12 .venv)
fi
(cd .mls && uv pip install --python .venv/bin/python -r requirements.txt)
# mls's requirements.txt is incomplete — server.py also needs mlx_vlm and python-multipart
(cd .mls && uv pip install --python .venv/bin/python mlx-vlm python-multipart)

deactivate

# ── 5. Pull LLM ──
echo -e "${CYAN}[4/5] Pulling Qwen3.5-4B (via Ollama)...${RESET}"
# Ensure ollama daemon is up so `pull` can talk to it
if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
    nohup ollama serve >/tmp/translator-ollama.log 2>&1 &
    for _ in $(seq 1 20); do
        sleep 0.5
        curl -s http://localhost:11434/api/tags >/dev/null 2>&1 && break
    done
fi
ollama pull qwen3.5:4b

# ── 6. Pre-download ASR model weights ──
echo -e "${CYAN}[5/5] Pre-downloading Qwen3-ASR-1.7B-8bit weights...${RESET}"
.venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download("mlx-community/Qwen3-ASR-1.7B-8bit")
print("  ASR weights cached.")
PY

echo -e "\n${GREEN}${BOLD}✅ Setup complete!${RESET}\n"
echo -e "Run the translator with:"
echo -e "  ${CYAN}./run.sh${RESET}\n"
