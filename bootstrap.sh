#!/usr/bin/env bash
set -euo pipefail

INSTALLER_REPO_RAW_BASE="${INSTALLER_REPO_RAW_BASE:-https://raw.githubusercontent.com/WiZARDWZ/ascrapper-installer/main}"
INSTALLER_HOME="${INSTALLER_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ascrapper-installer}"
DEPLOY_SCRIPT="$INSTALLER_HOME/deploy.sh"
BOOTSTRAP_SCRIPT="$INSTALLER_HOME/bootstrap.sh"
WRAPPER_PATH="/usr/local/bin/ascrapper"

log() {
  echo -e "\n\033[1;32m[bootstrap]\033[0m $*"
}

warn() {
  echo -e "\n\033[1;33m[warn]\033[0m $*"
}

die() {
  echo -e "\n\033[1;31m[error]\033[0m $*"
  exit 1
}

sudo_if_needed() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

non_interactive_hint() {
  cat <<'MSG'
This installer is interactive. Use this command instead of curl|bash:
curl -fsSLo /tmp/bootstrap.sh <url> && bash /tmp/bootstrap.sh
MSG
}

read_tty() {
  local prompt="$1"
  local default_value="${2:-}"
  local result=""

  if [[ -e /dev/tty ]]; then
    if ! read -r -p "$prompt" result < /dev/tty; then
      return 1
    fi
    [[ -n "$result" ]] || result="$default_value"
  else
    [[ -n "$default_value" ]] || return 1
    result="$default_value"
  fi

  printf '%s' "$result"
}

ask_non_empty() {
  local prompt="$1"
  local fallback_value="${2:-}"
  local value=""

  while true; do
    if ! value="$(read_tty "$prompt" "$fallback_value")"; then
      return 1
    fi

    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi

    if [[ -z "$fallback_value" && ! -e /dev/tty ]]; then
      return 1
    fi

    warn "Value cannot be empty."
    fallback_value=""
  done
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

download_file() {
  local url="$1"
  local destination="$2"
  curl --connect-timeout 10 \
    --max-time 60 \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 2 \
    -fL \
    --show-error \
    --progress-bar \
    "$url" \
    -o "$destination"
}

ensure_installer_scripts() {
  mkdir -p "$INSTALLER_HOME"

  local deploy_url_primary="$INSTALLER_REPO_RAW_BASE/deploy.sh"
  local deploy_url_fallback="https://github.com/WiZARDWZ/ascrapper-installer/raw/main/deploy.sh"
  local bootstrap_url_primary="$INSTALLER_REPO_RAW_BASE/bootstrap.sh"
  local bootstrap_url_fallback="https://github.com/WiZARDWZ/ascrapper-installer/raw/main/bootstrap.sh"

  local tmp_deploy
  local tmp_bootstrap
  tmp_deploy="$(mktemp "$INSTALLER_HOME/.deploy.sh.XXXXXX")"
  tmp_bootstrap="$(mktemp "$INSTALLER_HOME/.bootstrap.sh.XXXXXX")"

  log "Downloading deploy.sh ..."
  if ! download_file "$deploy_url_primary" "$tmp_deploy"; then
    warn "Primary deploy.sh URL failed. Trying fallback..."
    download_file "$deploy_url_fallback" "$tmp_deploy" || die "Unable to download deploy.sh"
  fi

  log "Downloading bootstrap.sh ..."
  if ! download_file "$bootstrap_url_primary" "$tmp_bootstrap"; then
    warn "Primary bootstrap.sh URL failed. Trying fallback..."
    download_file "$bootstrap_url_fallback" "$tmp_bootstrap" || die "Unable to download bootstrap.sh"
  fi

  chmod +x "$tmp_deploy" "$tmp_bootstrap"
  mv -f "$tmp_deploy" "$DEPLOY_SCRIPT"
  mv -f "$tmp_bootstrap" "$BOOTSTRAP_SCRIPT"
}

install_wrapper_command() {
  log "Installing /usr/local/bin/ascrapper wrapper command..."
  local tmp_wrapper
  tmp_wrapper="$(mktemp)"

  cat > "$tmp_wrapper" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
INSTALLER_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/ascrapper-installer"
exec bash "$INSTALLER_HOME/deploy.sh" "$@"
WRAP

  chmod +x "$tmp_wrapper"
  sudo_if_needed mv -f "$tmp_wrapper" "$WRAPPER_PATH"
}

require_interactive_or_env() {
  if [[ -e /dev/tty ]]; then
    return
  fi

  local required_vars=(REPO_URL BRANCH APP_NAME AUTH_MODE TELEGRAM_BOT_TOKEN)

  if [[ -z "${AUTH_MODE:-}" && -z "${AUTH_CHOICE:-}" ]]; then
    non_interactive_hint
    exit 1
  fi

  for key in "${required_vars[@]}"; do
    if [[ "$key" == "AUTH_MODE" ]]; then
      continue
    fi
    if [[ -z "${!key:-}" ]]; then
      non_interactive_hint
      exit 1
    fi
  done
}

choose_auth_mode() {
  local choice_input="${AUTH_MODE:-${AUTH_CHOICE:-}}"

  while true; do
    if [[ -z "$choice_input" ]]; then
      echo
      echo "Select GitHub private repo access method:"
      echo "1) SSH Deploy Key"
      echo "2) GitHub Personal Access Token (PAT)"
      choice_input="$(read_tty 'Choice [1/2]: ' '')" || die "Could not read AUTH_MODE."
    fi

    case "$choice_input" in
      1|ssh|SSH)
        AUTH_MODE="ssh"
        return 0
        ;;
      2|pat|PAT)
        AUTH_MODE="pat"
        return 0
        ;;
      *)
        warn "Invalid choice. Please use 1/2 or ssh/pat."
        choice_input=""
        ;;
    esac
  done
}

choose_action() {
  local choice_input="${DEPLOY_ACTION:-}"

  while true; do
    if [[ -z "$choice_input" ]]; then
      echo
      echo "What would you like to do?"
      echo "1) Initial install / setup"
      echo "2) Update project (git pull + deps + restart service)"
      echo "3) Restart service only"
      echo "4) Update installer only"
      choice_input="$(read_tty 'Choice [1/2/3/4]: ' '1')" || die "Could not read DEPLOY_ACTION."
    fi

    case "$choice_input" in
      1|install)
        DEPLOY_ACTION="install"
        return 0
        ;;
      2|update)
        DEPLOY_ACTION="update"
        return 0
        ;;
      3|restart)
        DEPLOY_ACTION="restart"
        return 0
        ;;
      4|installer-update)
        DEPLOY_ACTION="installer-update"
        return 0
        ;;
      *)
        warn "Invalid choice."
        choice_input=""
        ;;
    esac
  done
}

main() {
  require_interactive_or_env
  ensure_prereqs
  ensure_installer_scripts
  install_wrapper_command

  local repo_url
  repo_url="$(ask_non_empty 'Enter target GitHub repo URL (SSH/HTTPS): ' "${REPO_URL:-}")" || die "Could not read REPO_URL."

  local branch
  branch="$(ask_non_empty 'Branch [main]: ' "${BRANCH:-main}")" || die "Could not read BRANCH."

  local app_name
  app_name="$(ask_non_empty 'App name [ascrapper]: ' "${APP_NAME:-ascrapper}")" || die "Could not read APP_NAME."

  choose_auth_mode

  local bot_token
  bot_token="$(ask_non_empty 'Enter TELEGRAM_BOT_TOKEN: ' "${TELEGRAM_BOT_TOKEN:-}")" || die "Could not read TELEGRAM_BOT_TOKEN."

  local proxy_url="${TELEGRAM_PROXY_URL:-}"
  if [[ -z "$proxy_url" ]]; then
    local proxy_choice
    proxy_choice="$(read_tty 'Need Telegram proxy? (y/N): ' 'n' || true)"
    if [[ "$proxy_choice" =~ ^[Yy]$ ]]; then
      proxy_url="$(ask_non_empty 'Enter TELEGRAM_PROXY_URL (example: http://127.0.0.1:10809): ' '')" \
        || die "Could not read TELEGRAM_PROXY_URL."
    fi
  fi

  choose_action

  log "Running deploy.sh..."
  AUTH_MODE="$AUTH_MODE" \
  REPO_URL="$repo_url" \
  BRANCH="$branch" \
  APP_NAME="$app_name" \
  TELEGRAM_BOT_TOKEN="$bot_token" \
  TELEGRAM_PROXY_URL="$proxy_url" \
  DEPLOY_ACTION="$DEPLOY_ACTION" \
  "$DEPLOY_SCRIPT"

  log "Completed. Run 'ascrapper' any time to open the menu."
}

main "$@"
