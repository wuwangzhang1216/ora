#!/bin/bash
# Launcher: ensures mls + ollama are running, then starts the translator.
# Stops any services it spawned on exit; leaves pre-existing services alone.
set -e

cd "$(dirname "$0")"

if [ ! -d ".venv" ]; then
    echo "No .venv found. Run ./setup.sh first." >&2
    exit 1
fi
# shellcheck disable=SC1091
source .venv/bin/activate

CYAN='\033[36m'; YELLOW='\033[33m'; GREEN='\033[32m'; RESET='\033[0m'

MLS_PORT=18321
OLLAMA_PORT=11434
MLS_DIR=".mls"
LOG_DIR="/tmp"
STARTED_MLS_PID=""
STARTED_OLLAMA_PID=""

cleanup() {
    if [ -n "$STARTED_MLS_PID" ]; then
        echo -e "\n${YELLOW}[stop] mls (pid $STARTED_MLS_PID)${RESET}"
        kill "$STARTED_MLS_PID" 2>/dev/null || true
    fi
    if [ -n "$STARTED_OLLAMA_PID" ]; then
        echo -e "${YELLOW}[stop] ollama (pid $STARTED_OLLAMA_PID)${RESET}"
        kill "$STARTED_OLLAMA_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

port_in_use() { lsof -ti:"$1" >/dev/null 2>&1; }

wait_for_http() {
    local url=$1 name=$2 max_sec=${3:-30} pid=${4:-}
    local tries=$((max_sec * 2))
    for _ in $(seq 1 "$tries"); do
        curl -s "$url" >/dev/null 2>&1 && return 0
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            echo "[run] $name process died during startup — check $LOG_DIR/translator-${name}.log" >&2
            return 1
        fi
        sleep 0.5
    done
    echo "[run] $name failed to become ready within ${max_sec}s" >&2
    return 1
}

# ── Ollama ──
if port_in_use "$OLLAMA_PORT"; then
    echo -e "${GREEN}[ok]${RESET} Ollama already running on :$OLLAMA_PORT"
else
    echo -e "${CYAN}[start] Ollama...${RESET}"
    nohup ollama serve >"$LOG_DIR/translator-ollama.log" 2>&1 &
    STARTED_OLLAMA_PID=$!
    wait_for_http "http://localhost:$OLLAMA_PORT/api/tags" "ollama" 30 "$STARTED_OLLAMA_PID"
fi

# ── mls ──
if port_in_use "$MLS_PORT"; then
    echo -e "${GREEN}[ok]${RESET} mls already running on :$MLS_PORT"
else
    echo -e "${CYAN}[start] mls (Qwen3-ASR-1.7B-8bit)...${RESET}"
    if [ ! -f "$MLS_DIR/.venv/bin/python" ]; then
        echo "[run] $MLS_DIR/.venv missing — run ./setup.sh first" >&2
        exit 1
    fi
    ( cd "$MLS_DIR" && nohup ./.venv/bin/python bin/server.py >"$LOG_DIR/translator-mls.log" 2>&1 & echo $! >/tmp/translator-mls.pid )
    STARTED_MLS_PID="$(cat /tmp/translator-mls.pid)"
    wait_for_http "http://127.0.0.1:$MLS_PORT/" "mls" 180 "$STARTED_MLS_PID"
fi

# ── Translator ──
echo -e "${CYAN}[run] Starting translator...${RESET}\n"
python main.py "$@"
