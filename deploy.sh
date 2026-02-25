#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-ascrapper}"
SERVICE_NAME="${SERVICE_NAME:-$APP_NAME}"
BRANCH="${BRANCH:-main}"
PY_BIN="${PY_BIN:-python3.11}"
INSTALL_CHROME="${INSTALL_CHROME:-1}"
REPO_URL="${REPO_URL:-}"
AUTH_MODE="${AUTH_MODE:-${AUTH_CHOICE:-}}"
DEPLOY_ACTION="${DEPLOY_ACTION:-}"
INSTALLER_REPO_RAW_BASE="${INSTALLER_REPO_RAW_BASE:-https://raw.githubusercontent.com/WiZARDWZ/ascrapper-installer/main}"
INSTALLER_HOME="${INSTALLER_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ascrapper-installer}"

RUN_USER="${SUDO_USER:-${USER}}"
RUN_GROUP="$(id -gn "$RUN_USER")"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
APP_DIR="${APP_DIR:-$RUN_HOME/apps/$APP_NAME}"

CONFIG_DIR="$RUN_HOME/.config/$APP_NAME"
CONFIG_FILE="$CONFIG_DIR/installer.conf"
TOKEN_FILE="$CONFIG_DIR/github_token"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="$APP_DIR/.env"

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*"
}

die() {
  echo "[ERROR] $*"
  exit 1
}

run_as_user() {
  if [[ "$(id -u)" -eq 0 ]]; then
    sudo -u "$RUN_USER" -H bash -lc "$*"
  else
    bash -lc "$*"
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_quotes() {
  local s="$1"
  if [[ "$s" =~ ^\".*\"$ ]]; then
    s="${s#\"}"
    s="${s%\"}"
  elif [[ "$s" =~ ^\'.*\'$ ]]; then
    s="${s#\'}"
    s="${s%\'}"
  fi
  printf '%s' "$s"
}

load_installer_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0

  while IFS='=' read -r key raw_value; do
    [[ -n "$key" ]] || continue
    [[ "$key" =~ ^# ]] && continue

    local value
    value="$(strip_quotes "$(trim "${raw_value:-}")")"

    case "$key" in
      REPO_URL)
        [[ -z "${REPO_URL:-}" ]] && REPO_URL="$value"
        ;;
      AUTH_MODE)
        [[ -z "${AUTH_MODE:-}" ]] && AUTH_MODE="$value"
        ;;
      BRANCH)
        [[ -z "${BRANCH:-}" ]] && BRANCH="$value"
        ;;
      APP_NAME)
        ;;
      INSTALL_CHROME)
        [[ -z "${INSTALL_CHROME:-}" ]] && INSTALL_CHROME="$value"
        ;;
    esac
  done < "$CONFIG_FILE"
}

save_installer_config() {
  run_as_user "mkdir -p '$CONFIG_DIR'"

  local tmp_file
  tmp_file="$(mktemp)"
  cat > "$tmp_file" <<CONFIGEOF
REPO_URL="$REPO_URL"
AUTH_MODE="$AUTH_MODE"
BRANCH="$BRANCH"
APP_NAME="$APP_NAME"
INSTALL_CHROME="$INSTALL_CHROME"
CONFIGEOF

  run_as_user "cat > '$CONFIG_FILE'" < "$tmp_file"
  run_as_user "chmod 600 '$CONFIG_FILE'"
  rm -f "$tmp_file"
}

reset_installer_config() {
  run_as_user "rm -f '$CONFIG_FILE'"
  REPO_URL=""
  AUTH_MODE=""
  log "Installer config reset. You will be prompted for repo/auth again."
}

extract_owner_repo() {
  local input="$1"
  if [[ "$input" =~ ^git@github.com:([^/]+)/([^/]+)\.git$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    return
  fi
  if [[ "$input" =~ ^https://github.com/([^/]+)/([^/]+?)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    return
  fi
  echo ""
}

normalize_repo_url_ssh() {
  local input="$1"
  if [[ "$input" =~ ^git@github.com:.+/.+\.git$ ]]; then
    echo "$input"
    return
  fi
  if [[ "$input" =~ ^https://github.com/([^/]+)/([^/]+?)(\.git)?$ ]]; then
    echo "git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
    return
  fi
  echo ""
}

build_pat_url() {
  local base_url="$1"
  local token="$2"
  local owner_repo
  owner_repo="$(extract_owner_repo "$base_url")"
  [[ -n "$owner_repo" ]] || { echo ""; return; }
  echo "https://${token}@github.com/${owner_repo}.git"
}

ensure_prerequisites() {
  log "Installing required packages..."
  $SUDO apt-get update
  $SUDO apt-get install -y software-properties-common
  $SUDO add-apt-repository -y ppa:deadsnakes/ppa || true
  $SUDO apt-get update
  $SUDO apt-get install -y \
    git curl ca-certificates unzip build-essential pkg-config \
    "$PY_BIN" "${PY_BIN}-venv" "${PY_BIN}-distutils" \
    libnss3 libatk-bridge2.0-0 libgtk-3-0 libgbm1 libx11-xcb1 \
    libxcomposite1 libxdamage1 libxrandr2 libasound2 fonts-liberation \
    xvfb

  if [[ "$INSTALL_CHROME" == "1" ]]; then
    log "Installing Google Chrome stable..."
    local tmp_deb="/tmp/google-chrome-stable_current_amd64.deb"
    curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o "$tmp_deb"
    $SUDO dpkg -i "$tmp_deb" || $SUDO apt-get -f install -y
    rm -f "$tmp_deb"
  fi
}

prompt_repo_url() {
  while true; do
    if [[ -z "$REPO_URL" ]]; then
      read -r -p "Enter GitHub repo URL (SSH/HTTPS): " REPO_URL
    fi

    if [[ -n "$(extract_owner_repo "$REPO_URL")" ]]; then
      return 0
    fi

    warn "Invalid REPO_URL format. Example: git@github.com:OWNER/REPO.git"
    REPO_URL=""
  done
}

setup_ssh_access() {
  local ssh_key="$RUN_HOME/.ssh/id_ed25519"
  run_as_user "mkdir -p '$RUN_HOME/.ssh' && chmod 700 '$RUN_HOME/.ssh'"

  if ! run_as_user "test -f '$ssh_key'"; then
    log "SSH key not found. Generating a new key..."
    run_as_user "ssh-keygen -t ed25519 -C 'deploy@server' -f '$ssh_key' -N ''"
  fi

  echo
  echo "Public key:"
  run_as_user "cat '${ssh_key}.pub'"
  echo
  echo "Add this key in GitHub: Repository -> Settings -> Deploy keys -> Add deploy key"
  read -r -p "Press Enter after adding the key..." _

  run_as_user "ssh -o StrictHostKeyChecking=accept-new -T git@github.com || true"

  local normalized
  normalized="$(normalize_repo_url_ssh "$REPO_URL")"
  [[ -n "$normalized" ]] || die "REPO_URL cannot be converted to SSH format."
  REPO_URL="$normalized"
}

setup_pat_access() {
  local token="${GITHUB_PAT:-}"
  run_as_user "mkdir -p '$CONFIG_DIR'"

  if [[ -z "$token" ]] && run_as_user "test -f '$TOKEN_FILE'"; then
    return 0
  fi

  if [[ -z "$token" ]]; then
    read -r -s -p "Enter GitHub PAT: " token
    echo
  fi

  [[ -n "$token" ]] || { warn "PAT is empty."; return 1; }

  run_as_user "cat > '$TOKEN_FILE' <<'TOK'
$token
TOK"
  run_as_user "chmod 600 '$TOKEN_FILE'"
  log "PAT saved to $TOKEN_FILE"
  return 0
}

check_repo_access() {
  local mode="$1"
  local test_url="$REPO_URL"

  if [[ "$mode" == "pat" ]]; then
    run_as_user "test -f '$TOKEN_FILE'" || return 1
    local token
    token="$(run_as_user "cat '$TOKEN_FILE'")"
    test_url="$(build_pat_url "$REPO_URL" "$token")"
    [[ -n "$test_url" ]] || return 1
  fi

  run_as_user "git ls-remote '$test_url' -h 'refs/heads/$BRANCH' >/dev/null 2>&1"
}

choose_auth_mode_interactive() {
  while true; do
    echo
    echo "Choose GitHub private repo access method:"
    echo "1) SSH Deploy Key (recommended)"
    echo "2) GitHub Personal Access Token (PAT)"
    echo "0) Exit"
    read -r -p "Your choice: " auth_choice

    case "$auth_choice" in
      1) AUTH_MODE="ssh"; return 0 ;;
      2) AUTH_MODE="pat"; return 0 ;;
      0) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

select_auth_and_validate() {
  local force_prompt="${1:-0}"

  [[ "$force_prompt" == "1" ]] && REPO_URL="" AUTH_MODE=""

  prompt_repo_url

  if [[ -z "$AUTH_MODE" ]]; then
    choose_auth_mode_interactive
  fi

  if [[ "$AUTH_MODE" == "ssh" ]] && check_repo_access "ssh"; then
    return 0
  fi

  if [[ "$AUTH_MODE" == "pat" ]] && check_repo_access "pat"; then
    return 0
  fi

  case "$AUTH_MODE" in
    ssh)
      setup_ssh_access
      check_repo_access "ssh" || return 1
      ;;
    pat)
      setup_pat_access || return 1
      check_repo_access "pat" || return 1
      ;;
    *)
      warn "Invalid AUTH_MODE: $AUTH_MODE"
      AUTH_MODE=""
      return 1
      ;;
  esac

  return 0
}

clone_or_update_repo() {
  local work_url="$REPO_URL"

  if [[ "$AUTH_MODE" == "pat" ]]; then
    local token
    token="$(run_as_user "cat '$TOKEN_FILE'")"
    work_url="$(build_pat_url "$REPO_URL" "$token")"
  fi

  run_as_user "mkdir -p '$(dirname "$APP_DIR")'"

  if [[ ! -d "$APP_DIR/.git" ]]; then
    log "Cloning repository..."
    run_as_user "git clone --branch '$BRANCH' '$work_url' '$APP_DIR'" || return 1
  else
    log "Updating repository..."
    run_as_user "git -C '$APP_DIR' remote set-url origin '$work_url'"
    run_as_user "git -C '$APP_DIR' fetch origin '$BRANCH'"
    run_as_user "git -C '$APP_DIR' checkout '$BRANCH'"
    run_as_user "git -C '$APP_DIR' pull --ff-only origin '$BRANCH'" || return 1
  fi

  run_as_user "git -C '$APP_DIR' remote set-url origin '$REPO_URL'"
  return 0
}

prepare_repo() {
  local force_prompt="${1:-0}"

  while true; do
    if ! select_auth_and_validate "$force_prompt"; then
      warn "Repository authentication failed. Please provide repo/auth again."
      force_prompt=1
      continue
    fi

    if clone_or_update_repo; then
      save_installer_config
      return 0
    fi

    warn "Clone/pull failed. Please verify repository URL/authentication."
    force_prompt=1
  done
}

setup_venv_deps() {
  run_as_user "cd '$APP_DIR' && '$PY_BIN' -m venv .venv"
  run_as_user "cd '$APP_DIR' && .venv/bin/python -m pip install --upgrade pip setuptools wheel"
  run_as_user "cd '$APP_DIR' && .venv/bin/python -m pip install -r requirements.txt"
}

upsert_env() {
  local key="$1"
  local value="$2"
  run_as_user "touch '$ENV_FILE'"

  if run_as_user "grep -q '^${key}=' '$ENV_FILE'"; then
    run_as_user "sed -i 's|^${key}=.*|${key}=${value}|' '$ENV_FILE'"
  else
    run_as_user "printf '%s=%s\n' '$key' '$value' >> '$ENV_FILE'"
  fi
}

env_get() {
  local key="$1"
  local file="$2"

  run_as_user "test -f '$file'" || { echo ""; return 0; }

  local line
  line="$(run_as_user "grep -m1 -E '^${key}=' '$file' || true")"
  [[ -n "$line" ]] || { echo ""; return 0; }

  local value
  value="${line#*=}"
  value="$(trim "$value")"
  value="$(strip_quotes "$value")"
  echo "$value"
}

choose_perf_profile() {
  local existing_profile
  existing_profile="$(env_get 'PERF_PROFILE' "$ENV_FILE")"

  while true; do
    echo
    echo "Select performance profile:"
    echo "1) Normal (recommended for stronger servers)"
    echo "2) Low-end (recommended for 1 CPU / 1 GB RAM)"

    local prompt="Your choice [1/2]"
    if [[ -n "$existing_profile" ]]; then
      prompt+=" (Enter to keep: $existing_profile)"
    fi
    prompt+=": "

    local choice
    read -r -p "$prompt" choice

    case "$choice" in
      "")
        if [[ "$existing_profile" =~ ^(normal|low)$ ]]; then
          PERF_PROFILE_SELECTED="$existing_profile"
          return 0
        fi
        ;;
      1|normal|NORMAL)
        PERF_PROFILE_SELECTED="normal"
        return 0
        ;;
      2|low|LOW|low-end|LOW-END)
        PERF_PROFILE_SELECTED="low"
        return 0
        ;;
    esac

    warn "Invalid profile selection."
  done
}

env_wizard() {
  run_as_user "mkdir -p '$APP_DIR' && touch '$ENV_FILE'"

  local token existing_token
  existing_token="$(env_get 'TELEGRAM_BOT_TOKEN' "$ENV_FILE")"
  token="${TELEGRAM_BOT_TOKEN:-}"

  if [[ -z "$token" && -n "$existing_token" ]]; then
    token="$existing_token"
  fi

  if [[ -z "$token" ]]; then
    read -r -p "Enter Telegram bot token: " token
    while [[ -z "$token" ]]; do
      warn "Token cannot be empty."
      read -r -p "Enter Telegram bot token: " token
    done
  fi
  upsert_env "TELEGRAM_BOT_TOKEN" "$token"

  local proxy_choice proxy_val
  proxy_val="${TELEGRAM_PROXY_URL:-$(env_get 'TELEGRAM_PROXY_URL' "$ENV_FILE")}"

  if [[ -n "${TELEGRAM_PROXY_URL:-}" ]]; then
    upsert_env "TELEGRAM_PROXY_URL" "$TELEGRAM_PROXY_URL"
  else
    read -r -p "Do you need a Telegram proxy? (y/N): " proxy_choice
    if [[ "$proxy_choice" =~ ^[Yy]$ ]]; then
      read -r -p "Enter proxy URL (example: http://127.0.0.1:10809): " proxy_val
      upsert_env "TELEGRAM_PROXY_URL" "$proxy_val"
    elif [[ -z "$proxy_val" ]]; then
      upsert_env "TELEGRAM_PROXY_URL" ""
    fi
  fi

  choose_perf_profile
  local perf_profile
  perf_profile="$PERF_PROFILE_SELECTED"

  local headless_value="0"
  local light_interval="180"
  local light_pages="2"
  local worker_tick="10"

  if [[ "$perf_profile" == "low" ]]; then
    headless_value="0"
    light_interval="600"
    light_pages="1"
    worker_tick="20"
  else
    local advanced_headless
    read -r -p "Enable advanced headless mode for Normal profile? (y/N): " advanced_headless
    if [[ "$advanced_headless" =~ ^[Yy]$ ]]; then
      headless_value="1"
    fi
  fi

  upsert_env "PERF_PROFILE" "$perf_profile"
  upsert_env "TELEGRAM_CONNECT_TIMEOUT" "30"
  upsert_env "TELEGRAM_READ_TIMEOUT" "30"
  upsert_env "HEADLESS" "$headless_value"
  upsert_env "LIGHT_CHECK_INTERVAL_SECONDS" "$light_interval"
  upsert_env "LIGHT_CHECK_PAGES" "$light_pages"
  upsert_env "WORKER_TICK_SECONDS" "$worker_tick"
  upsert_env "DB_PATH" "realestate.db"
  upsert_env "OUTPUT_DIR" "output"
  upsert_env "PYTHONUNBUFFERED" "1"
}

ensure_token_present() {
  local token
  token="$(env_get 'TELEGRAM_BOT_TOKEN' "$ENV_FILE")"

  if [[ -z "$token" ]]; then
    warn "TELEGRAM_BOT_TOKEN is empty. Starting .env wizard..."
    env_wizard
    token="$(env_get 'TELEGRAM_BOT_TOKEN' "$ENV_FILE")"
    [[ -n "$token" ]] || die "TELEGRAM_BOT_TOKEN is still empty. Service cannot start."
  fi
}

write_service() {
  local perf_profile xvfb_screen exec_start
  perf_profile="$(env_get 'PERF_PROFILE' "$ENV_FILE")"

  case "$perf_profile" in
    low)
      xvfb_screen="1365x768x24"
      ;;
    *)
      xvfb_screen="1920x1080x24"
      ;;
  esac

  exec_start="/usr/bin/xvfb-run -a -s \"-screen 0 ${xvfb_screen}\" ${APP_DIR}/.venv/bin/python telegram_bot.py"

  $SUDO tee "$SERVICE_FILE" >/dev/null <<SERVICEEOF
[Unit]
Description=${APP_NAME} bot service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${exec_start}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$SERVICE_NAME"
}

restart_service() {
  ensure_token_present
  $SUDO systemctl restart "$SERVICE_NAME"
  log "Service ${SERVICE_NAME} restarted."
}

stop_service() {
  $SUDO systemctl stop "$SERVICE_NAME" || true
  log "Service ${SERVICE_NAME} stopped."
}

show_status_logs() {
  $SUDO systemctl status "$SERVICE_NAME" --no-pager || true
  $SUDO journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
}

download_installer_file() {
  local file_name="$1"
  local destination="$2"
  local tmp_file
  tmp_file="$(mktemp "$INSTALLER_HOME/.${file_name}.XXXXXX")"

  curl --connect-timeout 10 \
    --max-time 60 \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 2 \
    -fL \
    --show-error \
    --progress-bar \
    "$INSTALLER_REPO_RAW_BASE/$file_name" \
    -o "$tmp_file"

  chmod +x "$tmp_file"
  mv -f "$tmp_file" "$destination"
}

update_installer_only() {
  run_as_user "mkdir -p '$INSTALLER_HOME'"

  local deploy_target="$INSTALLER_HOME/deploy.sh"
  local bootstrap_target="$INSTALLER_HOME/bootstrap.sh"

  log "Updating installer scripts only..."
  download_installer_file "deploy.sh" "$deploy_target"
  download_installer_file "bootstrap.sh" "$bootstrap_target"

  log "Installer updated. Re-run 'ascrapper' to use the newest menu."
  log "No bot service actions were performed."
}

install_setup_flow() {
  ensure_prerequisites
  prepare_repo 0
  setup_venv_deps
  env_wizard
  write_service
  restart_service
  echo
  echo "Deploy complete"
  echo "Env file: $ENV_FILE"
  echo "Logs: journalctl -u $SERVICE_NAME -f"
  echo "Restart: sudo systemctl restart $SERVICE_NAME"
}

update_flow() {
  prepare_repo 0
  setup_venv_deps
  restart_service
  show_status_logs
}

restart_only_flow() {
  restart_service
  show_status_logs
}

menu_loop() {
  while true; do
    echo
    echo "===== $APP_NAME deploy menu ====="
    echo "1) Initial install / setup"
    echo "2) Update code from GitHub + deps + restart service"
    echo "3) Restart service"
    echo "4) Stop service"
    echo "5) Show status and logs"
    echo "6) Reconfigure token/proxy (.env wizard)"
    echo "7) Update installer only (no bot/service changes)"
    echo "8) Reset saved installer config (repo/auth)"
    echo "0) Exit"
    read -r -p "Your choice: " choice

    case "$choice" in
      1) install_setup_flow ;;
      2) update_flow ;;
      3) restart_only_flow ;;
      4) stop_service ;;
      5) show_status_logs ;;
      6) env_wizard ;;
      7) update_installer_only ;;
      8) reset_installer_config ;;
      0) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

main() {
  load_installer_config

  case "$DEPLOY_ACTION" in
    install)
      install_setup_flow
      ;;
    update)
      update_flow
      ;;
    restart)
      restart_only_flow
      ;;
    installer-update)
      update_installer_only
      ;;
    reset-config)
      reset_installer_config
      ;;
    "")
      if [[ -d "$APP_DIR" && -f "$SERVICE_FILE" ]]; then
        menu_loop
      else
        install_setup_flow
      fi
      ;;
    *)
      die "Unknown DEPLOY_ACTION: $DEPLOY_ACTION"
      ;;
  esac
}

main "$@"
