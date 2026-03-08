#!/usr/bin/env bash
# Install and wire up GitHub Copilot in the shell via gh-copilot.
# Usage: bash scripts/copilot-setup.sh
set -euo pipefail

log() { echo -e "\033[1;34m[copilot]\033[0m $*"; }

if ! command -v gh >/dev/null 2>&1; then
  log "GitHub CLI not found — installing via apt …"
  if ! command -v sudo >/dev/null 2>&1; then
    log "sudo is required to install gh. Please install gh manually: https://github.com/cli/cli#installation"
    exit 1
  fi
  sudo apt-get update -qq
  sudo apt-get install -y curl ca-certificates
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y gh
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
gh copilot alias --shell bash >> "$HOME/.bashrc"
gh copilot alias --shell zsh >> "$HOME/.zshrc" || true

log "Creating copilot shim in /usr/local/bin …"
echo -e "#!/usr/bin/env bash\nexec gh copilot \"\$@\"" | sudo tee /usr/local/bin/copilot >/dev/null
sudo chmod +x /usr/local/bin/copilot
if ! echo "$PATH" | tr ':' '\n' | grep -qx "/usr/local/bin"; then
  echo 'export PATH="/usr/local/bin:$PATH"' >> "$HOME/.bashrc"
fi

log "Checking Copilot status …"
gh copilot status || true

log "Done. Start a new shell or run 'exec \"$SHELL\"' to load PATH/aliases."
