#!/bin/bash
# Connects this Mac to the private queue repo as a GitHub Actions runner, so every Send rings the doorbell.
# Usage: ./scripts/install-runner.sh <owner/queue-repo> <registration token from GitHub>   (safe to run again)
set -euo pipefail
REPO_SLUG="${1:?usage: install-runner.sh owner/queue-repo TOKEN}"
TOKEN="${2:?paste the token GitHub shows under Settings → Actions → Runners → New self-hosted runner}"
DIR="$HOME/actions-runner-slopecycle"
mkdir -p "$DIR" && cd "$DIR"
if [[ ! -x ./config.sh ]]; then
  URL=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | grep -o '"browser_download_url": *"[^"]*osx-arm64[^"]*\.tar\.gz"' | head -1 | cut -d'"' -f4)
  [[ -n "$URL" ]] || { echo "Could not find the runner download. Check your internet connection."; exit 1; }
  echo "Downloading the GitHub runner…"
  curl -fsSL -o runner.tgz "$URL" && tar xzf runner.tgz && rm runner.tgz
fi
[[ -f .runner ]] && { ./svc.sh stop 2>/dev/null || true; ./svc.sh uninstall 2>/dev/null || true; ./config.sh remove --token "$TOKEN" || true; }
./config.sh --unattended --url "https://github.com/$REPO_SLUG" --token "$TOKEN" \
  --name "$(scutil --get ComputerName | tr -c 'A-Za-z0-9-' '-')-slopecycle" --labels slopecycle-processor --work _work --replace
./svc.sh install && ./svc.sh start
echo
echo "✅ Runner connected. On GitHub: queue repo → Settings → Actions → Runners should show it as Idle."
