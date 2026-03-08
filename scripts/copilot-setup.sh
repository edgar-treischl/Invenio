#!/usr/bin/env bash
# Install and wire up GitHub Copilot in the shell via gh-copilot.
# Usage: bash scripts/copilot-setup.sh
set -euo pipefail

log() { echo -e "\033[1;34m[copilot]\033[0m $*"; }

if ! command -v gh >/dev/null 2>&1; then
  log "GitHub CLI (gh) is required. Install it first: https://github.com/cli/cli#installation"
  exit 1
fi

if ! gh auth status -h github.com >/dev/null 2>&1; then
  log "gh is not authenticated. Run: gh auth login"
  exit 1
fi

log "Installing/refreshing gh-copilot extension …"
gh extension install github/gh-copilot >/dev/null 2>&1 || gh extension upgrade github/gh-copilot >/dev/null 2>&1

log "Requesting Copilot scope on your token …"
gh auth refresh -h github.com -s "copilot" >/dev/null

log "Creating shell aliases (bash/zsh) …"
gh copilot alias --shell bash >/dev/null
gh copilot alias --shell zsh >/dev/null || true

log "Checking Copilot status …"
gh copilot status || true

log "Done. Start a new shell or run 'exec \"$SHELL\"' to load the aliases."
