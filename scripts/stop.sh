#!/bin/bash
# Stops the agent and removes it from login items. Nothing in Drive or the sheet is touched.
# To also disconnect Google: in n8n, Credentials > SlopeCycle Google > Delete, then remove the app at
# https://myaccount.google.com/permissions
for label in com.slopecycle.wake com.slopecycle.n8n com.slopecycle.processor; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null && echo "stopped $label" || echo "$label was not running"
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
# The GitHub runner (if installed): stop it from waking anything up.
[[ -x "$HOME/actions-runner-slopecycle/svc.sh" ]] && (cd "$HOME/actions-runner-slopecycle" && ./svc.sh stop && ./svc.sh uninstall) || true
echo "To disconnect the runner from GitHub entirely: queue repo → Settings → Actions → Runners → remove it."
