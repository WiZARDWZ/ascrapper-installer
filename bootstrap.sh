#!/usr/bin/env bash
set -euo pipefail

INSTALLER_REPO_RAW_BASE="${INSTALLER_REPO_RAW_BASE:-https://raw.githubusercontent.com/WiZARDWZ/ascrapper-installer/main}"
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$BOOTSTRAP_DIR/deploy.sh"

log() { echo -e "\n\033[1;32m[bootstrap]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[warn]\033[0m $*"; }
err() { echo -e "\n\033[1;31m[error]\033[0m $*"; }

sudo_if_needed() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_prereqs() {
  log "Installing prerequisites for Ubuntu 22.04 headless..."
  sudo_if_needed apt-get update -y
  sudo_if_needed apt-get install -y software-properties-common
  sudo_if_needed add-apt-repository -y ppa:deadsnakes/ppa || true
  sudo_if_needed apt-get update -y
  sudo_if_needed apt-get install -y \
    git curl ca-certificates unzip build-essential pkg-config \
    python3.11 python3.11-venv python3.11-distutils
}

ensure_deploy_script() {
  if [[ -x "$DEPLOY_SCRIPT" ]]; then
    return
  fi

  if [[ -f "$DEPLOY_SCRIPT" ]]; then
    chmod +x "$DEPLOY_SCRIPT"
    return
  fi

  log "Downloading deploy.sh from installer repository..."
  curl -fsSL "$INSTALLER_REPO_RAW_BASE/deploy.sh" -o "$DEPLOY_SCRIPT"
  chmod +x "$DEPLOY_SCRIPT"
}

ask_non_empty() {
  local prompt="$1"
  local value=""
  while [[ -z "$value" ]]; do
    read -r -p "$prompt" value
  done
  printf '%s' "$value"
}

choose_auth_mode() {
  while true; do
    echo
    echo "Select GitHub private repo access method:"
    echo "1) SSH Deploy Key"
    echo "2) GitHub Personal Access Token (PAT)"
    read -r -p "Choice [1/2]: " choice
    case "$choice" in
      1) AUTH_MODE="ssh"; return ;;
      2) AUTH_MODE="pat"; return ;;
      *) warn "Invalid choice. Please use 1 or 2." ;;
    esac
  done
}

choose_action() {
  while true; do
    echo
    echo "What do you want to do now?"
    echo "1) Initial install / setup"
    echo "2) Update project (git pull + deps + restart service)"
    echo "3) Restart service only"
    read -r -p "Choice [1/2/3]: " choice
    case "$choice" in
      1) DEPLOY_ACTION="install"; return ;;
      2) DEPLOY_ACTION="update"; return ;;
      3) DEPLOY_ACTION="restart"; return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

main() {
  ensure_prereqs
  ensure_deploy_script

  local repo_url
  repo_url="$(ask_non_empty 'Enter target GitHub repo URL (SSH/HTTPS): ')"

  choose_auth_mode

  local bot_token
  bot_token="$(ask_non_empty 'Enter TELEGRAM_BOT_TOKEN: ')"

  local proxy_url=""
  read -r -p "Need Telegram proxy? (y/N): " proxy_choice
  if [[ "$proxy_choice" =~ ^[Yy]$ ]]; then
    proxy_url="$(ask_non_empty 'Enter TELEGRAM_PROXY_URL (e.g. http://127.0.0.1:10809): ')"
  fi

  choose_action

  log "Running deploy.sh..."
  AUTH_MODE="$AUTH_MODE" \
  REPO_URL="$repo_url" \
  TELEGRAM_BOT_TOKEN="$bot_token" \
  TELEGRAM_PROXY_URL="$proxy_url" \
  DEPLOY_ACTION="$DEPLOY_ACTION" \
  "$DEPLOY_SCRIPT"

  log "Completed. Manage service with: sudo systemctl [status|restart|stop] ascrapper"
}

main "$@"
