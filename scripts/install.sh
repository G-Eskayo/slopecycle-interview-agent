#!/bin/bash
# Installs or updates the SlopeCycle interview agent on the Processor Mac. Safe to run again.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
ENV_FILE="$HOME/.slopecycle.env"
say() { printf '\n==> %s\n' "$*"; }

[[ "$(uname -m)" == arm64 ]] || { echo "Needs an Apple Silicon Mac."; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || { echo "Needs macOS 14 or later (15+ recommended)."; exit 1; }
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Run: xcode-select --install   then re-run this script."; exit 1; }

say "Installing tools (skips anything already installed)"
# n8n refuses newer Node majors; pin 22 (LTS) and put it first on PATH for npm and the n8n service.
for pkg in uv node@22; do brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"; done
export PATH="$(brew --prefix node@22)/bin:$PATH"
brew list --cask ollama >/dev/null 2>&1 || command -v ollama >/dev/null || brew install --cask ollama
command -v n8n >/dev/null || npm install -g n8n

say "Building the transcriber and the wake-up helper"
(cd "$REPO/transcriber" && swift build -c release)
(cd "$REPO/wake" && swift build -c release)
TRANSCRIBE="$REPO/transcriber/.build/release/slope-transcribe"
WAKE="$REPO/wake/.build/release/slope-wake"

say "Installing the processor"
(cd "$REPO/processor" && uv sync --no-dev)

[[ -f "$ENV_FILE" ]] || cp "$REPO/.env.example" "$ENV_FILE"
chmod 600 "$ENV_FILE"   # holds the processor's GitHub key
set -a; source "$ENV_FILE"; set +a

say "Starting Ollama and downloading the model (about 5 GB the first time)"
open -a Ollama 2>/dev/null || true
for _ in $(seq 30); do curl -sf http://127.0.0.1:11434/api/version >/dev/null && break; sleep 1; done
ollama pull "${SLOPE_MODEL:-qwen3:8b}"

say "Registering background services (start at login)"
mkdir -p "$AGENTS" "$HOME/Library/Logs/slopecycle"
UV="$(command -v uv)"; N8N="$(command -v n8n)"; NODE_DIR="$(brew --prefix node@22)/bin"
write_agent() { # label, program args (xml), extra env (xml)
  cat > "$AGENTS/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$1</string>
<key>ProgramArguments</key><array>$2</array>
<key>EnvironmentVariables</key><dict>
<key>PATH</key><string>$NODE_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
$3</dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$HOME/Library/Logs/slopecycle/$1.log</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/slopecycle/$1.log</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENTS/$1.plist"
}
write_agent com.slopecycle.processor \
  "<string>$UV</string><string>run</string><string>--no-dev</string><string>--project</string><string>$REPO/processor</string><string>uvicorn</string><string>slope_processor.app:app</string><string>--host</string><string>127.0.0.1</string><string>--port</string><string>8787</string>" \
  "<key>SLOPE_TRANSCRIBE_BIN</key><string>$TRANSCRIBE</string><key>SLOPE_ENV_FILE</key><string>$ENV_FILE</string>"
# n8n listens on this Mac only, and keeps no copies of interview content in its run history (ADR 0006).
write_agent com.slopecycle.n8n "<string>$N8N</string><string>start</string>" \
  "<key>N8N_HOST</key><string>127.0.0.1</string><key>N8N_LISTEN_ADDRESS</key><string>127.0.0.1</string><key>GENERIC_TIMEZONE</key><string>America/Denver</string><key>EXECUTIONS_DATA_SAVE_ON_SUCCESS</key><string>none</string><key>EXECUTIONS_DATA_SAVE_ON_ERROR</key><string>none</string><key>EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS</key><string>false</string><key>EXECUTIONS_DATA_PRUNE</key><string>true</string><key>EXECUTIONS_DATA_MAX_AGE</key><string>24</string><key>N8N_DIAGNOSTICS_ENABLED</key><string>false</string>"
write_agent com.slopecycle.wake "<string>$WAKE</string><string>${SLOPE_RUN_NOW_URL:-http://127.0.0.1:5678/webhook/slopecycle-run}</string>" ""

say "Checking"
for _ in $(seq 30); do curl -sf http://127.0.0.1:8787/health >/dev/null && break; sleep 1; done
curl -sf http://127.0.0.1:8787/health && echo "  processor OK"
for _ in $(seq 60); do curl -sf http://127.0.0.1:5678/healthz >/dev/null && break; sleep 1; done
curl -sf http://127.0.0.1:5678/healthz >/dev/null && echo "  n8n OK: open http://127.0.0.1:5678"
echo
[[ -n "${SLOPE_QUEUE_REPO:-}" && -n "${SLOPE_QUEUE_TOKEN:-}" ]] || echo "  ! Fill in SLOPE_QUEUE_REPO and SLOPE_QUEUE_TOKEN in $ENV_FILE, then run this again."
echo
echo "Next: docs/SETUP.md Part 5 (n8n account)."
